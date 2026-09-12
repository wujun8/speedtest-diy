use argh::FromArgs;
use chrono::{DateTime, SecondsFormat, Utc};
use comfy_table::{presets::UTF8_FULL, Cell, Table};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use std::time::{SystemTime, UNIX_EPOCH};
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

static CLOUDFLARE_SPEEDTEST_BASE_URL: &str = "https://speed.cloudflare.com";
static CLOUDFLARE_SPEEDTEST_CGI_URL: &str = "https://speed.cloudflare.com/cdn-cgi/trace";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Direction {
    Download,
    Upload,
    Both,
}

impl Direction {
    fn from_args(args: &UserArgs) -> Self {
        match (args.download_only, args.upload_only) {
            (true, false) => Self::Download,
            (false, true) => Self::Upload,
            _ => Self::Both,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Download => "download",
            Self::Upload => "upload",
            Self::Both => "download/upload",
        }
    }
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

impl std::fmt::Display for AttemptFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RateLimited(_) => formatter.write_str("HTTP 429 retry budget exhausted"),
            Self::HttpStatus(status) => write!(formatter, "HTTP status {status}"),
            Self::Transport => formatter.write_str("transport error"),
            Self::InvalidBodyLength { expected, actual } => write!(
                formatter,
                "invalid response body length: expected {expected}, actual {actual}"
            ),
        }
    }
}

impl std::error::Error for AttemptFailure {}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
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

type RetryLogger = Arc<dyn Fn(Direction, u64) + Send + Sync>;

struct DirectionState {
    inner: Mutex<DirectionStateInner>,
    retry_logger: Mutex<Option<RetryLogger>>,
    direction: Mutex<Direction>,
}

impl Default for DirectionState {
    fn default() -> Self {
        Self {
            inner: Mutex::new(DirectionStateInner::default()),
            retry_logger: Mutex::new(None),
            direction: Mutex::new(Direction::Download),
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

    fn stop_normally(&self) {
        self.lock_inner().stop = true;
    }

    fn set_retry_logger(&self, retry_logger: RetryLogger) {
        *self
            .retry_logger
            .lock()
            .unwrap_or_else(|_| panic!("direction retry logger mutex is poisoned")) =
            Some(retry_logger);
    }

    fn retry_logger(&self) -> Option<RetryLogger> {
        self.retry_logger
            .lock()
            .unwrap_or_else(|_| panic!("direction retry logger mutex is poisoned"))
            .clone()
    }

    fn set_direction(&self, direction: Direction) {
        *self
            .direction
            .lock()
            .unwrap_or_else(|_| panic!("direction mutex is poisoned")) = direction;
    }

    fn direction(&self) -> Direction {
        *self
            .direction
            .lock()
            .unwrap_or_else(|_| panic!("direction mutex is poisoned"))
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
    let url = format!(
        "{}/__down?measId={meas_id}&bytes={requested_bytes}",
        base_url.trim_end_matches('/')
    );
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
        std::io::copy(&mut response.body_mut().as_reader(), &mut std::io::sink())
            .map_err(|_| AttemptFailure::Transport)?;
        return Err(AttemptFailure::RateLimited(retry_after));
    }
    if !(200..300).contains(&status) {
        std::io::copy(&mut response.body_mut().as_reader(), &mut std::io::sink())
            .map_err(|_| AttemptFailure::Transport)?;
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
    let url = format!("{}/__up?measId={meas_id}", base_url.trim_end_matches('/'));
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
        std::io::copy(&mut response.body_mut().as_reader(), &mut std::io::sink())
            .map_err(|_| AttemptFailure::Transport)?;
        return Err(AttemptFailure::RateLimited(retry_after));
    }
    if !(200..300).contains(&status) {
        std::io::copy(&mut response.body_mut().as_reader(), &mut std::io::sink())
            .map_err(|_| AttemptFailure::Transport)?;
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
    if message.is_empty() {
        return String::new();
    }

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

struct ThreadSafeLogger<W: std::io::Write + Send> {
    writer: Arc<Mutex<W>>,
}

impl<W: std::io::Write + Send> ThreadSafeLogger<W> {
    fn new(writer: Arc<Mutex<W>>) -> Self {
        Self { writer }
    }

    fn log_at(&self, timestamp: DateTime<Utc>, message: &str) -> std::io::Result<()> {
        let formatted = format_timestamped_lines(timestamp, message);
        if formatted.is_empty() {
            return Ok(());
        }

        let mut writer = self.writer.lock().map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::Other, "logger writer mutex is poisoned")
        })?;
        writer.write_all(formatted.as_bytes())?;
        writer.flush()
    }

    fn log(&self, message: &str) -> std::io::Result<()> {
        self.log_at(Utc::now(), message)
    }
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

fn run_worker_cycle_with_retry_log<N, S, A, L>(
    direction: Direction,
    state: &DirectionState,
    gate: &RuntimeRequestGate,
    mut attempt: A,
    mut now_ms: N,
    mut sleeper: S,
    mut retry_logger: L,
) -> std::result::Result<(), AttemptFailure>
where
    N: FnMut() -> u64,
    S: FnMut(u64),
    A: FnMut(u64) -> std::result::Result<TransferSample, AttemptFailure>,
    L: FnMut(Direction, u64),
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
                            retry_logger(direction, delay_secs);
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

fn run_worker_cycle<N, S, A>(
    state: &DirectionState,
    gate: &RuntimeRequestGate,
    attempt: A,
    now_ms: N,
    sleeper: S,
) -> std::result::Result<(), AttemptFailure>
where
    N: FnMut() -> u64,
    S: FnMut(u64),
    A: FnMut(u64) -> std::result::Result<TransferSample, AttemptFailure>,
{
    let retry_logger = state.retry_logger();
    let direction = state.direction();
    run_worker_cycle_with_retry_log(
        direction,
        state,
        gate,
        attempt,
        now_ms,
        sleeper,
        move |direction, delay_secs| {
            if let Some(retry_logger) = &retry_logger {
                retry_logger(direction, delay_secs);
            }
        },
    )
}

fn classify_single_direction_run_result(state: &DirectionState) -> DirectionRunResult {
    let snapshot = state.snapshot();
    if snapshot.valid_sample_count == 0 {
        DirectionRunResult::NoValidSamples
    } else if snapshot.terminal_error.is_some() {
        DirectionRunResult::TerminalFailure
    } else {
        DirectionRunResult::SuccessTable
    }
}

fn run_direction_for_cycles<N, S, A>(
    direction: Direction,
    cycles: usize,
    state: &DirectionState,
    gate: &RuntimeRequestGate,
    attempt: A,
    now_ms: N,
    sleeper: S,
) -> DirectionRunResult
where
    N: FnMut() -> u64,
    S: FnMut(u64),
    A: FnMut(u64) -> std::result::Result<TransferSample, AttemptFailure>,
{
    let mut attempt = attempt;
    let mut now_ms = now_ms;
    let mut sleeper = sleeper;

    for _ in 0..cycles {
        if state.should_stop() {
            break;
        }

        let cycle_result = run_worker_cycle(state, gate, &mut attempt, &mut now_ms, &mut sleeper);
        if cycle_result.is_err() || state.should_stop() {
            break;
        }
    }

    match direction {
        Direction::Download | Direction::Upload | Direction::Both => {
            classify_single_direction_run_result(state)
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

// Use cloudflare's cdn-cgi endpoint to get our ip address country
fn get_our_ip_address_country() -> Result<String> {
    let mut response = ureq::get(CLOUDFLARE_SPEEDTEST_CGI_URL)
        .config()
        .http_status_as_error(false)
        .build()
        .call()?;
    let status = response.status().as_u16();
    let body = response.body_mut().read_to_string()?;
    if !(200..300).contains(&status) {
        return Err(Box::new(AttemptFailure::HttpStatus(status)));
    }

    for line in body.lines() {
        if let Some(loc) = line.strip_prefix("loc=") {
            return Ok(loc.to_string());
        }
    }

    Err(Box::new(std::io::Error::new(
        std::io::ErrorKind::InvalidData,
        "Could not find loc= in cdn-cgi response",
    )))
}

// Get http latency by requesting the cgi endpoint 8 times
// and taking the fastest
fn get_download_server_http_latency() -> Result<std::time::Duration> {
    let start = Instant::now();
    let my_agent = create_configured_agent();
    let mut latency_vec = Vec::new();

    for _ in 0..LATENCY_TEST_COUNT {
        if latency_vec.len() >= 2 && start.elapsed() > Duration::from_secs(1) {
            break;
        }

        let now = Instant::now();
        let mut response = my_agent
            .get(CLOUDFLARE_SPEEDTEST_CGI_URL)
            .config()
            .http_status_as_error(false)
            .build()
            .call()?;
        let status = response.status().as_u16();
        response.body_mut().read_to_string()?;
        if !(200..300).contains(&status) {
            return Err(Box::new(AttemptFailure::HttpStatus(status)));
        }
        latency_vec.push(now.elapsed());
    }

    latency_vec.into_iter().min().ok_or_else(|| {
        Box::new(std::io::Error::new(
            std::io::ErrorKind::Other,
            "Could not measure server latency",
        )) as Box<dyn std::error::Error>
    })
}

fn get_download_server_info(agent: &Agent, base_url: &str) -> Result<String> {
    let url = format!(
        "{}/__down?measId={}&bytes=0",
        base_url.trim_end_matches('/'),
        next_meas_id()
    );
    let mut response = agent
        .get(url)
        .config()
        .http_status_as_error(false)
        .build()
        .call()?;
    let status = response.status().as_u16();
    let retry_after = response
        .headers()
        .get("Retry-After")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let body = response.body_mut().read_to_string()?;

    if status == 429 {
        return Err(Box::new(AttemptFailure::RateLimited(retry_after)));
    }
    if !(200..300).contains(&status) {
        return Err(Box::new(AttemptFailure::HttpStatus(status)));
    }

    Ok(body)
}

fn print_test_preamble<W: std::io::Write + Send>(logger: &ThreadSafeLogger<W>) -> Result<()> {
    logger.log("Start:")?;

    let our_country = get_our_ip_address_country()?;
    let our_country_full = locations::CCA2_TO_COUNTRY_NAME
        .get(our_country.as_str())
        .copied()
        .unwrap_or("UNKNOWN");
    let latency = get_download_server_http_latency()?;
    let agent = create_configured_agent();
    let server_info = get_download_server_info(&agent, CLOUDFLARE_SPEEDTEST_BASE_URL)?;
    let server_info = if server_info.trim().is_empty() {
        "(empty)"
    } else {
        server_info.trim()
    };

    logger.log(&format!("{:<32} {}", "Your Location:", our_country_full))?;
    logger.log(&format!("{:<32} {}", "Server Info:", server_info))?;
    logger.log(&format!(
        "{:<32} {:.2}ms",
        "Latency (HTTP):",
        latency.as_millis()
    ))?;
    Ok(())
}

fn elapsed_millis(origin: Instant) -> u64 {
    origin.elapsed().as_millis().min(u64::MAX as u128) as u64
}

fn run_direction_for_runtime<W: std::io::Write + Send + 'static>(
    direction: Direction,
    thread_count: u32,
    requested_bytes: usize,
    duration_seconds: u64,
    base_url: &str,
    logger: Arc<ThreadSafeLogger<W>>,
) -> Result<DirectionStateSnapshot> {
    if matches!(direction, Direction::Both) {
        return Err(Box::new(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "runtime runner accepts one direction at a time",
        )));
    }

    let state = Arc::new(DirectionState::default());
    state.set_direction(direction);
    let gate = Arc::new(RuntimeRequestGate::new());
    let clock = Instant::now();
    let deadline = clock
        .checked_add(Duration::from_secs(duration_seconds))
        .ok_or_else(|| {
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "test duration is too large",
            )) as Box<dyn std::error::Error>
        })?;
    let fatal_stop = Arc::new(AtomicBool::new(false));
    let workers_started = Arc::new(AtomicUsize::new(0));
    let retry_log_error = Arc::new(Mutex::new(None::<String>));
    let base_url = base_url.trim_end_matches('/').to_owned();

    let retry_log_error_for_callback = Arc::clone(&retry_log_error);
    let fatal_stop_for_callback = Arc::clone(&fatal_stop);
    let state_weak = Arc::downgrade(&state);
    let logger_for_callback = Arc::clone(&logger);
    state.set_retry_logger(Arc::new(move |retry_direction, delay_secs| {
        let message = format!(
            "{}: HTTP 429 retrying in {} second{}",
            retry_direction.label(),
            delay_secs,
            if delay_secs == 1 { "" } else { "s" }
        );
        if let Err(error) = logger_for_callback.log(&message) {
            let mut stored_error = retry_log_error_for_callback
                .lock()
                .unwrap_or_else(|_| panic!("retry log error mutex is poisoned"));
            if stored_error.is_none() {
                *stored_error = Some(format!("logger write failed: {error}"));
            }
            fatal_stop_for_callback.store(true, Ordering::SeqCst);
            if let Some(state) = state_weak.upgrade() {
                state.stop_normally();
            }
        }
    }));

    if duration_seconds == 0 {
        state.stop_normally();
    }

    let mut handles: Vec<JoinHandle<std::result::Result<(), String>>> = Vec::new();
    for _ in 0..thread_count {
        let state = Arc::clone(&state);
        let gate = Arc::clone(&gate);
        let fatal_stop = Arc::clone(&fatal_stop);
        let workers_started = Arc::clone(&workers_started);
        let retry_log_error = Arc::clone(&retry_log_error);
        let base_url = base_url.clone();

        handles.push(std::thread::spawn(move || {
            if duration_seconds == 0 || state.should_stop() {
                return Ok(());
            }

            let agent = create_configured_agent();
            let mut first_cycle = true;

            loop {
                if fatal_stop.load(Ordering::SeqCst) || state.should_stop() {
                    break;
                }
                if first_cycle {
                    workers_started.fetch_add(1, Ordering::SeqCst);
                    first_cycle = false;
                } else if Instant::now() >= deadline {
                    if workers_started.load(Ordering::SeqCst) >= thread_count as usize {
                        state.stop_normally();
                        break;
                    }
                    std::thread::yield_now();
                    continue;
                }

                let cycle_result = run_worker_cycle(
                    &state,
                    &gate,
                    |meas_id| match direction {
                        Direction::Download => {
                            download_once(&agent, &base_url, requested_bytes, meas_id)
                        }
                        Direction::Upload => {
                            upload_once(&agent, &base_url, requested_bytes, meas_id)
                        }
                        Direction::Both => Err(AttemptFailure::Transport),
                    },
                    || elapsed_millis(clock),
                    |delay_ms| {
                        if fatal_stop.load(Ordering::SeqCst) || state.should_stop() {
                            return;
                        }

                        let now = Instant::now();
                        let remaining = deadline.saturating_duration_since(now);
                        if remaining.is_zero() {
                            if workers_started.load(Ordering::SeqCst) >= thread_count as usize {
                                state.stop_normally();
                            }
                            return;
                        }

                        let delay = Duration::from_millis(delay_ms);
                        if delay >= remaining {
                            std::thread::sleep(remaining);
                            if workers_started.load(Ordering::SeqCst) >= thread_count as usize {
                                state.stop_normally();
                            }
                        } else {
                            std::thread::sleep(delay);
                        }
                    },
                );

                if fatal_stop.load(Ordering::SeqCst) {
                    let error = retry_log_error
                        .lock()
                        .unwrap_or_else(|_| panic!("retry log error mutex is poisoned"))
                        .clone()
                        .unwrap_or_else(|| "fatal worker stop".to_owned());
                    return Err(error);
                }
                if cycle_result.is_err() {
                    break;
                }
                if Instant::now() >= deadline {
                    state.stop_normally();
                    break;
                }
            }

            Ok(())
        }));
    }

    if duration_seconds > 0 {
        loop {
            if state.should_stop() || fatal_stop.load(Ordering::SeqCst) {
                break;
            }
            if handles.iter().any(|handle| handle.is_finished()) {
                state.stop_normally();
                break;
            }

            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                if workers_started.load(Ordering::SeqCst) >= thread_count as usize {
                    state.stop_normally();
                    break;
                }
                std::thread::yield_now();
                continue;
            }
            std::thread::sleep(remaining.min(Duration::from_millis(25)));
        }
    } else {
        state.stop_normally();
    }

    if !state.should_stop() {
        state.stop_normally();
    }

    let mut join_error = None;
    for handle in handles {
        match handle.join() {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                if join_error.is_none() {
                    join_error = Some(error);
                }
            }
            Err(_) => {
                if join_error.is_none() {
                    join_error = Some("worker thread panicked".to_owned());
                }
            }
        }
    }

    if let Some(error) = join_error {
        return Err(Box::new(std::io::Error::new(
            std::io::ErrorKind::Other,
            error,
        )));
    }

    Ok(state.snapshot())
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

fn requested_missing_direction(
    direction: Direction,
    download_snapshot: &DirectionStateSnapshot,
    upload_snapshot: &DirectionStateSnapshot,
) -> Option<&'static str> {
    match direction {
        Direction::Download if download_snapshot.valid_sample_count == 0 => Some("download"),
        Direction::Upload if upload_snapshot.valid_sample_count == 0 => Some("upload"),
        Direction::Both if download_snapshot.valid_sample_count == 0 => Some("download"),
        Direction::Both if upload_snapshot.valid_sample_count == 0 => Some("upload"),
        _ => None,
    }
}

fn requested_terminal_failure<'a>(
    direction: Direction,
    download_snapshot: &'a DirectionStateSnapshot,
    upload_snapshot: &'a DirectionStateSnapshot,
) -> Option<(&'static str, &'a AttemptFailure)> {
    match direction {
        Direction::Download => download_snapshot
            .terminal_error
            .as_ref()
            .map(|failure| ("download", failure)),
        Direction::Upload => upload_snapshot
            .terminal_error
            .as_ref()
            .map(|failure| ("upload", failure)),
        Direction::Both => download_snapshot
            .terminal_error
            .as_ref()
            .map(|failure| ("download", failure))
            .or_else(|| {
                upload_snapshot
                    .terminal_error
                    .as_ref()
                    .map(|failure| ("upload", failure))
            }),
    }
}

fn run_program<W: std::io::Write + Send>(
    args: &UserArgs,
    download_snapshot: &DirectionStateSnapshot,
    upload_snapshot: &DirectionStateSnapshot,
    logger: &ThreadSafeLogger<W>,
) -> i32 {
    if let Err(error) = args.validate() {
        return if logger.log(&format!("ERROR: {error}")).is_ok() {
            2
        } else {
            1
        };
    }

    let direction = Direction::from_args(args);
    if let Some(missing_direction) =
        requested_missing_direction(direction, download_snapshot, upload_snapshot)
    {
        return if logger
            .log(&format!("ERROR: no valid {missing_direction} samples"))
            .is_ok()
        {
            3
        } else {
            1
        };
    }

    if let Some((failed_direction, failure)) =
        requested_terminal_failure(direction, download_snapshot, upload_snapshot)
    {
        return if logger
            .log(&format!(
                "ERROR: {failed_direction} transfer failed: {failure}"
            ))
            .is_ok()
        {
            1
        } else {
            1
        };
    }

    let mut download_rates: Vec<usize> = match direction {
        Direction::Download | Direction::Both => download_snapshot
            .measurements
            .iter()
            .map(|sample| sample.bytes_per_second)
            .collect(),
        Direction::Upload => Vec::new(),
    };
    let mut upload_rates: Vec<usize> = match direction {
        Direction::Upload | Direction::Both => upload_snapshot
            .measurements
            .iter()
            .map(|sample| sample.bytes_per_second)
            .collect(),
        Direction::Download => Vec::new(),
    };

    let (download_median, download_avg, download_p90, _, _, _) =
        compute_statistics(&mut download_rates);
    let (upload_median, upload_avg, upload_p90, _, _, _) = compute_statistics(&mut upload_rates);

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

    let table_text = table.to_string();
    if logger.log(&table_text).is_ok() {
        0
    } else {
        1
    }
}

fn parse_command_line<W: std::io::Write + Send>(
    logger: &ThreadSafeLogger<W>,
) -> std::result::Result<UserArgs, i32> {
    let raw_arguments: Vec<_> = std::env::args_os().collect();
    let mut arguments = Vec::with_capacity(raw_arguments.len());
    for argument in raw_arguments {
        match argument.into_string() {
            Ok(argument) => arguments.push(argument),
            Err(_) => {
                if logger
                    .log("ERROR: invalid UTF-8 command-line argument")
                    .is_err()
                {
                    return Err(1);
                }
                return Err(2);
            }
        }
    }

    if arguments.is_empty() {
        if logger.log("ERROR: command name is missing").is_err() {
            return Err(1);
        }
        return Err(2);
    }

    let command_name = arguments[0].as_str();
    let argument_refs: Vec<&str> = arguments[1..].iter().map(String::as_str).collect();
    match UserArgs::from_args(&[command_name], &argument_refs) {
        Ok(args) => Ok(args),
        Err(early_exit) => {
            let status = if early_exit.status.is_ok() { 0 } else { 2 };
            let message = if status == 0 {
                early_exit.output
            } else {
                format!(
                    "ERROR: {}\nRun {} --help for more information.",
                    early_exit.output.trim_end(),
                    command_name
                )
            };
            if logger.log(&message).is_err() {
                Err(1)
            } else {
                Err(status)
            }
        }
    }
}

fn run_main<W: std::io::Write + Send + 'static>(logger: Arc<ThreadSafeLogger<W>>) -> i32 {
    let config = match parse_command_line(&logger) {
        Ok(config) => config,
        Err(code) => return code,
    };

    if let Err(error) = config.validate() {
        return if logger.log(&format!("ERROR: {error}")).is_ok() {
            2
        } else {
            1
        };
    }

    if let Err(error) = print_test_preamble(&logger) {
        let _ = logger.log(&format!("ERROR: preamble failed: {error}"));
        return 1;
    }

    let direction = Direction::from_args(&config);
    let mut download_snapshot = DirectionStateSnapshot::default();
    let mut upload_snapshot = DirectionStateSnapshot::default();

    if matches!(direction, Direction::Download | Direction::Both) {
        if logger.log("Starting download tests...").is_err() {
            return 1;
        }
        match run_direction_for_runtime(
            Direction::Download,
            config.download_threads,
            config.bytes_to_download,
            config.test_duration_seconds,
            CLOUDFLARE_SPEEDTEST_BASE_URL,
            Arc::clone(&logger),
        ) {
            Ok(snapshot) => download_snapshot = snapshot,
            Err(error) => {
                let _ = logger.log(&format!("ERROR: download runtime failed: {error}"));
                return 1;
            }
        }
    }

    if matches!(direction, Direction::Upload | Direction::Both) {
        if logger.log("Starting upload tests...").is_err() {
            return 1;
        }
        match run_direction_for_runtime(
            Direction::Upload,
            config.upload_threads,
            config.bytes_to_upload,
            config.test_duration_seconds,
            CLOUDFLARE_SPEEDTEST_BASE_URL,
            Arc::clone(&logger),
        ) {
            Ok(snapshot) => upload_snapshot = snapshot,
            Err(error) => {
                let _ = logger.log(&format!("ERROR: upload runtime failed: {error}"));
                return 1;
            }
        }
    }

    run_program(&config, &download_snapshot, &upload_snapshot, &logger)
}

fn main() -> std::process::ExitCode {
    let logger = Arc::new(ThreadSafeLogger::new(Arc::new(Mutex::new(
        std::io::stdout(),
    ))));
    std::process::ExitCode::from(run_main(logger) as u8)
}
