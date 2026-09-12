use chrono::{DateTime, SecondsFormat, Utc};
use comfy_table::{presets::UTF8_FULL, Cell, Table};
use std::io::Read;
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread::JoinHandle;
use std::time::Instant;
use std::time::{SystemTime, UNIX_EPOCH};
use std::vec;
use ureq::Agent;

mod args;
use args::UserArgs;

mod agent;
use crate::agent::create_configured_agent;

mod locations;
#[cfg(test)]
#[rustfmt::skip]
mod tests;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

static CLOUDFLARE_SPEEDTEST_DOWNLOAD_URL: &str = "https://speed.cloudflare.com/__down?measId=0";
static CLOUDFLARE_SPEEDTEST_UPLOAD_URL: &str = "https://speed.cloudflare.com/__up?measId=0";
static CLOUDFLARE_SPEEDTEST_SERVER_URL: &str =
    "https://speed.cloudflare.com/__down?measId=0&bytes=0";
static CLOUDFLARE_SPEEDTEST_CGI_URL: &str = "https://speed.cloudflare.com/cdn-cgi/trace";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Direction {
    Download,
    Upload,
    Both,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RetryDecision {
    Retry { delay_secs: u64 },
    Abort,
    NoRetry,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RetryPolicy {
    max_retries: usize,
    fallback_delay_secs: u64,
    max_delay_secs: u64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 2,
            fallback_delay_secs: 1,
            max_delay_secs: 30,
        }
    }
}

impl RetryPolicy {
    fn decide(
        &self,
        status: u16,
        retry_after: Option<&str>,
        attempt_index: usize,
    ) -> RetryDecision {
        if status != 429 {
            return RetryDecision::NoRetry;
        }

        if attempt_index >= self.max_retries {
            return RetryDecision::Abort;
        }

        match retry_after.and_then(parse_retry_after_seconds) {
            Some(delay_secs) if (1..=self.max_delay_secs).contains(&delay_secs) => {
                RetryDecision::Retry { delay_secs }
            }
            Some(delay_secs) if delay_secs > self.max_delay_secs => RetryDecision::Abort,
            _ => RetryDecision::Retry {
                delay_secs: self
                    .fallback_delay_secs
                    .saturating_add(attempt_index as u64),
            },
        }
    }
}

fn parse_retry_after_seconds(value: &str) -> Option<u64> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }

    value.parse::<u64>().ok()
}

#[derive(Debug, Default)]
struct RequestGateState {
    next_start_ms: u64,
}

impl RequestGateState {
    fn reserve_start_ms(&mut self, now_ms: u64) -> u64 {
        let start_ms = self.next_start_ms.max(now_ms);
        self.next_start_ms = start_ms.saturating_add(250);
        start_ms
    }

    fn extend_retry_deadline_ms(&mut self, deadline_ms: u64) {
        self.next_start_ms = self.next_start_ms.max(deadline_ms);
    }
}

const REQUEST_START_SPACING_MS: u64 = 250;

#[derive(Debug, Default)]
struct RuntimeRequestGateState {
    next_start_ms: u64,
    retry_deadline_ms: u64,
}

struct RuntimeRequestGate {
    state: Mutex<RuntimeRequestGateState>,
}

impl RuntimeRequestGate {
    fn new() -> Self {
        Self {
            state: Mutex::new(RuntimeRequestGateState::default()),
        }
    }

    fn lock_state(&self) -> MutexGuard<'_, RuntimeRequestGateState> {
        self.state
            .lock()
            .unwrap_or_else(|_| panic!("runtime request gate mutex is poisoned"))
    }

    fn extend_retry_deadline_ms(&self, deadline_ms: u64) {
        let mut state = self.lock_state();
        state.retry_deadline_ms = state.retry_deadline_ms.max(deadline_ms);
    }

    fn wait_for_start_with<N, S>(&self, mut now_ms: N, mut sleeper: S) -> u64
    where
        N: FnMut() -> u64,
        S: FnMut(u64),
    {
        let (mut reserved_start_ms, mut observed_retry_deadline_ms) = {
            let mut state = self.lock_state();
            let retry_deadline_ms = state.retry_deadline_ms;
            let start_ms = now_ms().max(state.next_start_ms).max(retry_deadline_ms);
            state.next_start_ms = start_ms.saturating_add(REQUEST_START_SPACING_MS);
            (start_ms, retry_deadline_ms)
        };

        loop {
            let now = now_ms();
            let mut state = self.lock_state();
            if state.retry_deadline_ms > observed_retry_deadline_ms {
                reserved_start_ms = reserved_start_ms
                    .max(state.retry_deadline_ms)
                    .max(state.next_start_ms);
                state.next_start_ms = reserved_start_ms.saturating_add(REQUEST_START_SPACING_MS);
                observed_retry_deadline_ms = state.retry_deadline_ms;
            }

            if now >= reserved_start_ms {
                let actual_start_ms = now;
                state.next_start_ms = state
                    .next_start_ms
                    .max(actual_start_ms.saturating_add(REQUEST_START_SPACING_MS));
                return actual_start_ms;
            }

            let delay_ms = reserved_start_ms - now;
            drop(state);
            sleeper(delay_ms);
        }
    }
}

static MEAS_ID_SEED: OnceLock<u64> = OnceLock::new();
static MEAS_ID_COUNTER: AtomicU64 = AtomicU64::new(0);

fn initialize_meas_id_seed() -> u64 {
    let clock_nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let process_id = u64::from(std::process::id());
    let counter_address = (&MEAS_ID_COUNTER as *const AtomicU64 as usize) as u64;
    let seed = clock_nanos ^ process_id.rotate_left(32) ^ counter_address.rotate_left(17);

    if seed == 0 {
        1
    } else {
        seed
    }
}

fn next_meas_id() -> u64 {
    let seed = *MEAS_ID_SEED.get_or_init(initialize_meas_id_seed);

    loop {
        let sequence = MEAS_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
        let id = seed.wrapping_add(sequence);
        if id != 0 {
            return id;
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TransferSample {
    bytes: usize,
    bytes_per_second: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum AttemptFailure {
    RateLimited(Option<String>),
    HttpStatus(u16),
    Transport,
    InvalidBodyLength { expected: usize, actual: usize },
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DirectionStateSnapshot {
    valid_sample_count: usize,
    confirmed_bytes: usize,
    measurements: Vec<TransferSample>,
    terminal_error: Option<AttemptFailure>,
}

#[derive(Debug, Default)]
struct DirectionStateInner {
    valid_sample_count: usize,
    confirmed_bytes: usize,
    measurements: Vec<TransferSample>,
    terminal_error: Option<AttemptFailure>,
    stop: bool,
}

struct DirectionState {
    inner: Mutex<DirectionStateInner>,
}

impl Default for DirectionState {
    fn default() -> Self {
        Self {
            inner: Mutex::new(DirectionStateInner::default()),
        }
    }
}

impl DirectionState {
    fn lock_inner(&self) -> MutexGuard<'_, DirectionStateInner> {
        self.inner
            .lock()
            .unwrap_or_else(|_| panic!("direction state mutex is poisoned"))
    }

    fn record_sample(&self, sample: TransferSample) {
        let mut state = self.lock_inner();
        if state.stop {
            return;
        }

        state.valid_sample_count = state.valid_sample_count.saturating_add(1);
        state.confirmed_bytes = state.confirmed_bytes.saturating_add(sample.bytes);
        state.measurements.push(sample);
    }

    fn record_terminal_error(&self, failure: AttemptFailure) {
        let mut state = self.lock_inner();
        state.stop = true;
        if state.terminal_error.is_none() {
            state.terminal_error = Some(failure);
        }
    }

    fn snapshot(&self) -> DirectionStateSnapshot {
        let state = self.lock_inner();
        DirectionStateSnapshot {
            valid_sample_count: state.valid_sample_count,
            confirmed_bytes: state.confirmed_bytes,
            measurements: state.measurements.clone(),
            terminal_error: state.terminal_error.clone(),
        }
    }

    fn should_stop(&self) -> bool {
        self.lock_inner().stop
    }
}

fn transfer_sample(bytes: usize, started_at: Instant) -> TransferSample {
    let elapsed_nanos = started_at.elapsed().as_nanos().max(1);
    let bytes_per_second = (bytes as u128)
        .saturating_mul(1_000_000_000)
        .checked_div(elapsed_nanos)
        .unwrap_or(0)
        .min(usize::MAX as u128) as usize;

    TransferSample {
        bytes,
        bytes_per_second: if bytes == 0 {
            0
        } else {
            bytes_per_second.max(1)
        },
    }
}

fn download_once(
    agent: &Agent,
    base_url: &str,
    requested_bytes: usize,
    meas_id: u64,
) -> std::result::Result<TransferSample, AttemptFailure> {
    let started_at = Instant::now();
    let url = format!("{base_url}/__down?measId={meas_id}&bytes={requested_bytes}");
    let mut response = agent
        .get(url)
        .config()
        .http_status_as_error(false)
        .build()
        .call()
        .map_err(|_| AttemptFailure::Transport)?;

    let status = response.status().as_u16();
    if status == 429 {
        let retry_after = response
            .headers()
            .get("Retry-After")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        return Err(AttemptFailure::RateLimited(retry_after));
    }
    if !(200..300).contains(&status) {
        return Err(AttemptFailure::HttpStatus(status));
    }

    let actual_bytes = std::io::copy(&mut response.body_mut().as_reader(), &mut std::io::sink())
        .map_err(|_| AttemptFailure::Transport)?;
    let actual_bytes = usize::try_from(actual_bytes).unwrap_or(usize::MAX);
    if actual_bytes != requested_bytes {
        return Err(AttemptFailure::InvalidBodyLength {
            expected: requested_bytes,
            actual: actual_bytes,
        });
    }

    Ok(transfer_sample(actual_bytes, started_at))
}

fn upload_once(
    agent: &Agent,
    base_url: &str,
    requested_bytes: usize,
    meas_id: u64,
) -> std::result::Result<TransferSample, AttemptFailure> {
    let started_at = Instant::now();
    let url = format!("{base_url}/__up?measId={meas_id}");
    let body = vec![1u8; requested_bytes];
    let mut response = agent
        .post(url)
        .header("Content-Type", "text/plain;charset=UTF-8")
        .config()
        .http_status_as_error(false)
        .build()
        .send(body)
        .map_err(|_| AttemptFailure::Transport)?;

    let status = response.status().as_u16();
    if status == 429 {
        let retry_after = response
            .headers()
            .get("Retry-After")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        return Err(AttemptFailure::RateLimited(retry_after));
    }
    if !(200..300).contains(&status) {
        return Err(AttemptFailure::HttpStatus(status));
    }

    std::io::copy(&mut response.body_mut().as_reader(), &mut std::io::sink())
        .map_err(|_| AttemptFailure::Transport)?;

    Ok(transfer_sample(requested_bytes, started_at))
}

fn execute_with_retry<F, S>(
    policy: RetryPolicy,
    mut attempt: F,
    mut sleeper: S,
) -> std::result::Result<TransferSample, AttemptFailure>
where
    F: FnMut(u64) -> std::result::Result<TransferSample, AttemptFailure>,
    S: FnMut(u64),
{
    let mut retry_index = 0;

    loop {
        let meas_id = next_meas_id();
        match attempt(meas_id) {
            Ok(sample) => return Ok(sample),
            Err(failure) => {
                let AttemptFailure::RateLimited(retry_after) = &failure else {
                    return Err(failure);
                };

                match policy.decide(429, retry_after.as_deref(), retry_index) {
                    RetryDecision::Retry { delay_secs } => {
                        let fallback_delay_secs = policy
                            .fallback_delay_secs
                            .saturating_add(retry_index as u64);
                        sleeper(delay_secs.max(fallback_delay_secs));
                        retry_index = retry_index.saturating_add(1);
                    }
                    RetryDecision::Abort | RetryDecision::NoRetry => return Err(failure),
                }
            }
        }
    }
}

fn build_request_url(direction: Direction, bytes: usize, id: u64) -> String {
    assert!(id != 0, "measurement id must be non-zero");

    match direction {
        Direction::Download => {
            format!("https://speed.cloudflare.com/__down?measId={id}&bytes={bytes}")
        }
        Direction::Upload => format!("https://speed.cloudflare.com/__up?measId={id}"),
        Direction::Both => panic!("cannot build a request URL for both directions"),
    }
}

fn is_valid_download_sample(requested: usize, body: &[u8]) -> bool {
    requested > 0 && body.len() == requested
}

fn format_timestamped_lines(timestamp: DateTime<Utc>, message: &str) -> String {
    let prefix = format!(
        "[{}] ",
        timestamp.to_rfc3339_opts(SecondsFormat::Millis, true)
    );
    let mut formatted = String::with_capacity(message.len() + prefix.len());

    for line in message.split_inclusive('\n') {
        formatted.push_str(&prefix);
        formatted.push_str(line);
    }

    formatted
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DirectionOutcome {
    SuccessTable,
    NonZeroFailure,
}

impl DirectionOutcome {
    fn exit_code(self) -> i32 {
        match self {
            Self::SuccessTable => 0,
            Self::NonZeroFailure => 3,
        }
    }

    fn has_success_table(self) -> bool {
        matches!(self, Self::SuccessTable)
    }
}

fn classify_direction_outcome(
    direction: Direction,
    download_samples: &[usize],
    upload_samples: &[usize],
) -> DirectionOutcome {
    let download_succeeded = download_samples.iter().any(|sample| *sample > 0);
    let upload_succeeded = upload_samples.iter().any(|sample| *sample > 0);
    let success = match direction {
        Direction::Download => download_succeeded,
        Direction::Upload => upload_succeeded,
        Direction::Both => download_succeeded && upload_succeeded,
    };

    if success {
        DirectionOutcome::SuccessTable
    } else {
        DirectionOutcome::NonZeroFailure
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DirectionRunResult {
    SuccessTable,
    TerminalFailure,
    NoValidSamples,
}

impl DirectionRunResult {
    fn exit_code(self) -> i32 {
        match self {
            Self::SuccessTable => 0,
            Self::TerminalFailure => 1,
            Self::NoValidSamples => 3,
        }
    }

    fn has_success_table(self) -> bool {
        matches!(self, Self::SuccessTable)
    }
}

fn classify_direction_run_result(
    direction: Direction,
    download_state: &DirectionState,
    upload_state: &DirectionState,
) -> DirectionRunResult {
    let download_snapshot = download_state.snapshot();
    let upload_snapshot = upload_state.snapshot();

    let requested_snapshots = match direction {
        Direction::Download => vec![download_snapshot],
        Direction::Upload => vec![upload_snapshot],
        Direction::Both => vec![download_snapshot, upload_snapshot],
    };

    if requested_snapshots
        .iter()
        .any(|snapshot| snapshot.valid_sample_count == 0)
    {
        DirectionRunResult::NoValidSamples
    } else if requested_snapshots
        .iter()
        .any(|snapshot| snapshot.terminal_error.is_some())
    {
        DirectionRunResult::TerminalFailure
    } else {
        DirectionRunResult::SuccessTable
    }
}

fn run_worker_cycle<N, S, A>(
    state: &DirectionState,
    gate: &RuntimeRequestGate,
    mut attempt: A,
    mut now_ms: N,
    mut sleeper: S,
) -> std::result::Result<(), AttemptFailure>
where
    N: FnMut() -> u64,
    S: FnMut(u64),
    A: FnMut(u64) -> std::result::Result<TransferSample, AttemptFailure>,
{
    let policy = RetryPolicy::default();
    let mut retry_index = 0;

    loop {
        if state.should_stop() {
            return Ok(());
        }

        gate.wait_for_start_with(&mut now_ms, &mut sleeper);
        if state.should_stop() {
            return Ok(());
        }

        let meas_id = next_meas_id();
        match attempt(meas_id) {
            Ok(sample) => {
                state.record_sample(sample);
                return Ok(());
            }
            Err(failure) => {
                if let AttemptFailure::RateLimited(retry_after) = &failure {
                    match policy.decide(429, retry_after.as_deref(), retry_index) {
                        RetryDecision::Retry { delay_secs } => {
                            let delay_ms = delay_secs.saturating_mul(1_000);
                            let retry_deadline_ms = now_ms().saturating_add(delay_ms);
                            gate.extend_retry_deadline_ms(retry_deadline_ms);
                            retry_index = retry_index.saturating_add(1);
                            continue;
                        }
                        RetryDecision::Abort | RetryDecision::NoRetry => {}
                    }
                }

                state.record_terminal_error(failure.clone());
                return Err(failure);
            }
        }
    }
}

static OUR_USER_AGENT: &str = concat!(
    "cf_speedtest (",
    env!("CARGO_PKG_VERSION"),
    ") https://github.com/12932/cf_speedtest"
);

static CONNECT_TIMEOUT_MILLIS: u64 = 9600;
static LATENCY_TEST_COUNT: u8 = 8;
static NEW_METAL_SLEEP_MILLIS: u32 = 250;

impl std::io::Read for UploadHelper {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        // upload is finished, or we are exiting
        if self.byte_ctr.load(Ordering::SeqCst) >= self.bytes_to_send
            || self.exit_signal.load(Ordering::SeqCst)
        {
            return Ok(0);
        }

        let bytes_remaining = self
            .bytes_to_send
            .saturating_sub(self.byte_ctr.load(Ordering::SeqCst));
        let bytes_to_fill = buf.len().min(bytes_remaining);
        if bytes_to_fill == 0 {
            return Ok(0);
        }

        buf[..bytes_to_fill].fill(1);

        self.byte_ctr.fetch_add(bytes_to_fill, Ordering::SeqCst);
        self.total_uploaded_counter
            .fetch_add(bytes_to_fill, Ordering::SeqCst);
        Ok(bytes_to_fill)
    }
}

struct UploadHelper {
    bytes_to_send: usize,
    byte_ctr: Arc<AtomicUsize>,
    total_uploaded_counter: Arc<AtomicUsize>,
    exit_signal: Arc<AtomicBool>,
}

fn get_secs_since_unix_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

// Default test duration + a little bit more if we have extra threads
fn get_test_time(test_duration_seconds: u64, thread_count: u32) -> u64 {
    if thread_count > 4 {
        return test_duration_seconds + (thread_count as u64 - 4) / 4;
    }

    test_duration_seconds
}

/* Given n bytes, return
     a: unit of measurement in sensible form of bytes
     b: unit of measurement in sensible form of bits
 i.e 12939428 	-> (12.34 MB, 98.76 Mb)
     814811 	-> (795.8 KB, 6.36 Mb)
*/
fn get_appropriate_byte_unit(bytes: u64) -> (String, String) {
    const UNITS: [&str; 5] = [" ", "K", "M", "G", "T"];
    const KILOBYTE: f64 = 1024.0;

    let mut bytes = bytes as f64;
    let mut level = 0;

    while bytes >= KILOBYTE && level < UNITS.len() - 1 {
        bytes /= KILOBYTE;
        level += 1;
    }

    let byte_unit = UNITS[level];
    let mut bits = bytes * 8.0;
    let mut bit_unit = byte_unit.to_ascii_lowercase();

    if bits >= 1000.0 {
        bits /= 1000.0;
        bit_unit = match byte_unit {
            " " => "k",
            "K" => "m",
            "M" => "g",
            "G" => "t",
            "T" => "p",
            _ => "?",
        }
        .to_string();
    }

    (
        format!("{:.2} {}B", bytes, byte_unit),
        format!("{:.2} {}b", bits, bit_unit),
    )
}

fn get_appropriate_byte_unit_rate(bytes: u64) -> (String, String) {
    let (a, b) = get_appropriate_byte_unit(bytes);
    (format!("{}/s", a), format!("{}it/s", b))
}

fn get_appropriate_buff_size(speed: usize) -> u64 {
    match speed {
        0..=1000 => 4,
        1001..=10000 => 32,
        10001..=100000 => 512,
        100001..=1000000 => 4096,
        _ => 16384,
    }
}

// Use cloudflare's cdn-cgi endpoint to get our ip address country
fn get_our_ip_address_country() -> Result<String> {
    let mut resp = ureq::get(CLOUDFLARE_SPEEDTEST_CGI_URL).call()?;
    let body: String = resp.body_mut().read_to_string()?;

    for line in body.lines() {
        if let Some(loc) = line.strip_prefix("loc=") {
            return Ok(loc.to_string());
        }
    }

    panic!(
        "Could not find loc= in cdn-cgi response\n
			Please update to the latest version and make a Github issue if the issue persists"
    );
}

// Get http latency by requesting the cgi endpoint 8 times
// and taking the fastest
fn get_download_server_http_latency() -> Result<std::time::Duration> {
    let start = Instant::now();

    let my_agent = create_configured_agent();
    let mut latency_vec = Vec::new();

    for _ in 0..LATENCY_TEST_COUNT {
        // if vec length 2 or greater and we've spent a lot of time
        // 	calculating latency, exit early (we could be on satellite or sumthin)
        if latency_vec.len() >= 2 && start.elapsed() > std::time::Duration::from_secs(1) {
            break;
        }

        let now = Instant::now();

        let _response = my_agent
            .get(CLOUDFLARE_SPEEDTEST_CGI_URL)
            .call()?
            .body_mut()
            .read_to_string();

        let total_time = now.elapsed();
        latency_vec.push(total_time);
    }

    let best_time = latency_vec.iter().min().unwrap().to_owned();
    Ok(best_time)
}

// return all cloufdlare headers from a request
fn get_download_server_info() -> Result<std::collections::HashMap<String, String>> {
    let mut server_headers = std::collections::HashMap::new();
    let resp = ureq::get(CLOUDFLARE_SPEEDTEST_SERVER_URL)
        .call()
        .expect("Failed to get server info");

    // Using headers() instead of headers_names()
    for header in resp.headers() {
        let key_str = header.0.as_str();
        if key_str.starts_with("cf-") {
            server_headers.insert(
                key_str.to_string(),
                header.1.to_str().unwrap_or_default().to_string(),
            );
        }
    }

    Ok(server_headers)
}

fn get_current_timestamp() -> String {
    let now = chrono::Local::now();

    format!("{} {}", now.format("%Y-%m-%d %H:%M:%S"), now.format("%Z"))
}

fn upload_test(
    bytes: usize,
    total_up_bytes_counter: &Arc<AtomicUsize>,
    _current_speed: &Arc<AtomicUsize>,
    exit_signal: &Arc<AtomicBool>,
) -> Result<()> {
    let agent: Agent = create_configured_agent();

    loop {
        let upload_helper = UploadHelper {
            bytes_to_send: bytes,
            byte_ctr: Arc::new(AtomicUsize::new(0)),
            total_uploaded_counter: total_up_bytes_counter.clone(),
            exit_signal: exit_signal.clone(),
        };

        let body = ureq::SendBody::from_owned_reader(upload_helper);

        let resp = match agent
            .post(CLOUDFLARE_SPEEDTEST_UPLOAD_URL)
            .header("Content-Type", "text/plain;charset=UTF-8")
            .send(body)
        {
            Ok(resp) => resp,
            Err(err) => {
                eprintln!("Error in upload thread: {err}");
                return Ok(());
            }
        };

        // Process the response
        let _ = std::io::copy(&mut resp.into_body().into_reader(), &mut std::io::sink());

        if exit_signal.load(Ordering::Relaxed) {
            return Ok(());
        }
    }
}

// download some bytes from cloudflare
fn download_test(
    bytes_to_request: usize,
    total_bytes_counter: &Arc<AtomicUsize>,
    current_down_speed: &Arc<AtomicUsize>,
    exit_signal: &Arc<AtomicBool>,
) -> Result<()> {
    let agent: Agent = create_configured_agent();

    let resp = match agent
        .get(format!("{CLOUDFLARE_SPEEDTEST_DOWNLOAD_URL}&bytes={bytes_to_request}").as_str())
        .call()
    {
        Ok(resp) => resp,
        Err(err) => {
            eprintln!("Error in download thread: {err}");
            return Ok(());
        }
    };

    let body = resp.into_body();
    let mut resp_reader = body.into_reader();
    let mut total_bytes_sank: usize = 0;

    loop {
        // exit if we have passed deadline
        if exit_signal.load(Ordering::Relaxed) {
            return Ok(());
        }

        // if we are fast, take big chunks
        // if we are slow, take small chunks
        let current_recv_buff =
            get_appropriate_buff_size(current_down_speed.load(Ordering::Relaxed));

        // copy bytes into the void
        let bytes_sank = std::io::copy(
            &mut resp_reader.by_ref().take(current_recv_buff),
            &mut std::io::sink(),
        )? as usize;

        //println!("Thread {:?} sank {} bytes", std::thread::current().id(), bytes_sank);

        if bytes_sank == 0 {
            if total_bytes_sank == 0 {
                eprintln!("Cloudflare sent an empty response?");
            }

            return Ok(());
        }

        total_bytes_sank += bytes_sank;
        total_bytes_counter.fetch_add(bytes_sank, Ordering::SeqCst);
    }
}

fn print_test_preamble() {
    println!("{:<32} {}", "Start:", get_current_timestamp());

    let our_country = get_our_ip_address_country().expect("Couldn't get our country");
    let our_country_full = locations::CCA2_TO_COUNTRY_NAME.get(&our_country as &str);
    let latency = get_download_server_http_latency().expect("Couldn't get server latency");
    let headers = get_download_server_info().expect("Couldn't get download server info");

    let unknown_colo = &"???".to_owned();
    let unknown_colo_info = &("UNKNOWN", "UNKNOWN");
    let cf_colo = headers.get("cf-meta-colo").unwrap_or(unknown_colo);
    let colo_info = locations::IATA_TO_CITY_COUNTRY
        .get(cf_colo as &str)
        .unwrap_or(unknown_colo_info);

    println!(
        "{:<32} {}",
        "Your Location:",
        our_country_full.unwrap_or(&"UNKNOWN")
    );
    println!(
        "{:<32} {} - {}, {}",
        "Server Location:",
        cf_colo,
        colo_info.0,
        locations::CCA2_TO_COUNTRY_NAME
            .get(colo_info.1)
            .unwrap_or(&"UNKNOWN")
    );

    println!("{:<32} {:.2}ms\n", "Latency (HTTP):", latency.as_millis());
}

// Spawn a given amount of threads to run a specific test
fn spawn_test_threads<F>(
    threads_to_spawn: u32,
    target_test: Arc<F>,
    bytes_to_request: usize,
    total_bytes_counter: &Arc<AtomicUsize>,
    current_speed: &Arc<AtomicUsize>,
    exit_signal: &Arc<AtomicBool>,
) -> Vec<JoinHandle<()>>
where
    F: Fn(
            usize,
            &Arc<AtomicUsize>,
            &Arc<AtomicUsize>,
            &Arc<AtomicBool>,
        ) -> std::result::Result<(), Box<dyn std::error::Error>>
        + Send
        + Sync
        + 'static,
{
    let mut thread_handles = vec![];

    for i in 0..threads_to_spawn {
        let target_test_clone = Arc::clone(&target_test);
        let total_downloaded_bytes_counter = Arc::clone(&total_bytes_counter.clone());
        let current_down_clone = Arc::clone(&current_speed.clone());
        let exit_signal_clone = Arc::clone(&exit_signal.clone());
        let handle = std::thread::spawn(move || {
            if i > 0 {
                // sleep a little to hit a new cloudflare metal
                // (each metal will throttle to 1 gigabit)
                std::thread::sleep(std::time::Duration::from_millis(
                    (i * NEW_METAL_SLEEP_MILLIS).into(),
                ));
            }

            loop {
                match target_test_clone(
                    bytes_to_request,
                    &total_downloaded_bytes_counter,
                    &current_down_clone,
                    &exit_signal_clone,
                ) {
                    Ok(_) => {}
                    Err(e) => {
                        println!("Error in download test thread {i}: {e:?}");
                        return;
                    }
                }

                // exit if we have passed the deadline
                if exit_signal_clone.load(Ordering::Relaxed) {
                    // println!("Thread {} exiting...", i);
                    return;
                }
            }
        });
        thread_handles.push(handle);
    }

    thread_handles
}

fn run_download_test(config: &UserArgs) -> Vec<usize> {
    let total_downloaded_bytes_counter = Arc::new(AtomicUsize::new(0));
    let exit_signal = Arc::new(AtomicBool::new(false));

    exit_signal.store(false, Ordering::SeqCst);
    let current_down_speed = Arc::new(AtomicUsize::new(0));
    let down_deadline = get_secs_since_unix_epoch()
        + get_test_time(config.test_duration_seconds, config.download_threads);

    let target_test = Arc::new(download_test);
    let down_handles = spawn_test_threads(
        config.download_threads,
        target_test,
        config.bytes_to_download,
        &total_downloaded_bytes_counter,
        &current_down_speed,
        &exit_signal,
    );

    let mut last_bytes_down = 0;
    total_downloaded_bytes_counter.store(0, Ordering::SeqCst);
    let mut down_measurements = vec![];

    // Calculate and print download speed
    loop {
        let bytes_down = total_downloaded_bytes_counter.load(Ordering::Relaxed);
        let bytes_down_diff = bytes_down - last_bytes_down;

        // set current_down
        current_down_speed.store(bytes_down_diff, Ordering::SeqCst);
        down_measurements.push(bytes_down_diff);

        let speed_values = get_appropriate_byte_unit(bytes_down_diff as u64);
        // only print progress if we are before deadline
        if get_secs_since_unix_epoch() < down_deadline {
            println!(
                "Download: {bit_speed:>12.*}it/s       ({byte_speed:>10.*}/s)",
                16,
                16,
                byte_speed = speed_values.0,
                bit_speed = speed_values.1
            );
        }
        io::stdout().flush().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1000));
        last_bytes_down = bytes_down;

        // exit if we have passed the deadline
        if get_secs_since_unix_epoch() > down_deadline {
            exit_signal.store(true, Ordering::SeqCst);
            break;
        }
    }

    println!("Waiting for download threads to finish...");
    for handle in down_handles {
        handle.join().expect("Couldn't join download thread");
    }

    down_measurements
}

fn run_upload_test(config: &UserArgs) -> Vec<usize> {
    let exit_signal = Arc::new(AtomicBool::new(false));
    let total_uploaded_bytes_counter = Arc::new(AtomicUsize::new(0));
    let current_up_speed = Arc::new(AtomicUsize::new(0));
    // re-use exit_signal for upload tests
    exit_signal.store(false, Ordering::SeqCst);

    let up_deadline = get_secs_since_unix_epoch()
        + get_test_time(config.test_duration_seconds, config.upload_threads);

    let target_test = Arc::new(upload_test);
    let up_handles = spawn_test_threads(
        config.upload_threads,
        target_test,
        config.bytes_to_upload,
        &total_uploaded_bytes_counter,
        &current_up_speed,
        &exit_signal,
    );

    let mut last_bytes_up = 0;
    let mut up_measurements = vec![];
    total_uploaded_bytes_counter.store(0, Ordering::SeqCst);

    // Calculate and print upload speed
    loop {
        let bytes_up = total_uploaded_bytes_counter.load(Ordering::Relaxed);

        let bytes_up_diff = bytes_up - last_bytes_up;
        up_measurements.push(bytes_up_diff);

        let speed_values = get_appropriate_byte_unit(bytes_up_diff as u64);

        println!(
            "Upload:   {bit_speed:>12.*}it/s       ({byte_speed:>10.*}/s)",
            16,
            16,
            byte_speed = speed_values.0,
            bit_speed = speed_values.1
        );

        io::stdout().flush().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(1000));
        last_bytes_up = bytes_up;

        // exit if we have passed the deadline
        if get_secs_since_unix_epoch() > up_deadline {
            exit_signal.store(true, Ordering::SeqCst);
            break;
        }
    }

    // wait for upload threads to finish
    println!("Waiting for upload threads to finish...");
    for handle in up_handles {
        handle.join().expect("Couldn't join upload thread");
    }

    up_measurements
}

fn compute_statistics(data: &mut [usize]) -> (f64, f64, usize, usize, usize, usize) {
    if data.is_empty() {
        return (0f64, 0f64, 0, 0, 0, 0);
    }

    data.sort();

    let len = data.len();
    let sum: usize = data.iter().sum();
    let average = sum as f64 / len as f64;

    let median = if len % 2 == 0 {
        (data[len / 2 - 1] + data[len / 2]) as f64 / 2.0
    } else {
        data[len / 2] as f64
    };

    let p90_index = (0.90 * len as f64).ceil() as usize - 1;
    let p99_index = (0.99 * len as f64).ceil() as usize - 1;

    let min = data[0];
    let max = *data.last().unwrap();

    (median, average, data[p90_index], data[p99_index], min, max)
}

fn main() {
    let config: UserArgs = argh::from_env();
    config.validate().expect("Invalid arguments");

    print_test_preamble();

    let mut down_measurements: Vec<usize> = Vec::new();
    let mut up_measurements: Vec<usize> = Vec::new();

    if !config.upload_only {
        down_measurements = run_download_test(&config);
    }

    if !config.download_only {
        println!("Starting upload tests...");
        up_measurements = run_upload_test(&config);
    }

    let (download_median, download_avg, download_p90, _, _, _) =
        compute_statistics(&mut down_measurements);
    let (upload_median, upload_avg, upload_p90, _, _, _) = compute_statistics(&mut up_measurements);

    let mut table = Table::new();
    table
        .load_preset(UTF8_FULL)
        .set_content_arrangement(comfy_table::ContentArrangement::Dynamic)
        .set_header(vec![
            Cell::new(""),
            Cell::new("Median"),
            Cell::new("Average"),
            Cell::new("90th pctile"),
        ]);

    // Populate rows based on computed statistics
    table.add_row(vec![
        Cell::new("DOWN"),
        Cell::new(get_appropriate_byte_unit_rate(download_median as u64).1),
        Cell::new(get_appropriate_byte_unit_rate(download_avg as u64).1),
        Cell::new(get_appropriate_byte_unit_rate(download_p90 as u64).1),
    ]);

    table.add_row(vec![
        Cell::new("UP"),
        Cell::new(get_appropriate_byte_unit_rate(upload_median as u64).1),
        Cell::new(get_appropriate_byte_unit_rate(upload_avg as u64).1),
        Cell::new(get_appropriate_byte_unit_rate(upload_p90 as u64).1),
    ]);

    print!("\n{}\n{}\n", get_current_timestamp(), table);
}
