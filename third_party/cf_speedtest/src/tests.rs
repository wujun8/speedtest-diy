use super::*;
use chrono::{DateTime, Utc};
use std::collections::HashSet;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const TEN_MEBIBYTES: usize = 10485760;

fn query_meas_id(url: &str) -> &str {
    url.split('?')
        .nth(1)
        .and_then(|query| {
            query
                .split('&')
                .find_map(|part| part.strip_prefix("measId="))
        })
        .expect("request URL must carry a measId query parameter")
}

fn assert_nonzero_without_success_table(outcome: DirectionOutcome) {
    assert_eq!(outcome, DirectionOutcome::NonZeroFailure);
    assert_ne!(outcome.exit_code(), 0);
    assert!(!outcome.has_success_table());
}

#[test]
fn defaults_use_ten_mebibytes_for_each_request() {
    let args = UserArgs::default();

    assert_eq!(args.bytes_to_download, TEN_MEBIBYTES);
    assert_eq!(args.bytes_to_upload, TEN_MEBIBYTES);
    assert_ne!(args.bytes_to_download, 0);
    assert_ne!(args.bytes_to_upload, 0);
}

#[test]
fn thread_counts_are_limited_to_one_through_sixty_four() {
    let defaults = UserArgs::default();
    assert!((1..=64).contains(&defaults.download_threads));
    assert!((1..=64).contains(&defaults.upload_threads));

    for threads in 1..=64 {
        let mut download_args = defaults.clone();
        download_args.download_threads = threads;
        assert!(
            download_args.validate().is_ok(),
            "download_threads={threads} should be accepted"
        );

        let mut upload_args = defaults.clone();
        upload_args.upload_threads = threads;
        assert!(
            upload_args.validate().is_ok(),
            "upload_threads={threads} should be accepted"
        );
    }

    for threads in [0, 65] {
        let mut download_args = defaults.clone();
        download_args.download_threads = threads;
        assert!(
            download_args.validate().is_err(),
            "download_threads={threads} should be rejected"
        );

        let mut upload_args = defaults.clone();
        upload_args.upload_threads = threads;
        assert!(
            upload_args.validate().is_err(),
            "upload_threads={threads} should be rejected"
        );
    }
}

#[test]
fn request_attempt_ids_are_positive_decimal_unique_and_bound_into_each_url() {
    let attempt_ids: Vec<u64> = (0..4).map(|_| next_meas_id()).collect();
    let unique_ids: HashSet<u64> = attempt_ids.iter().copied().collect();

    assert_eq!(unique_ids.len(), attempt_ids.len());
    assert!(attempt_ids.iter().all(|id| *id > 0));

    let download_url = build_request_url(Direction::Download, TEN_MEBIBYTES, attempt_ids[0]);
    let upload_url = build_request_url(Direction::Upload, TEN_MEBIBYTES, attempt_ids[1]);
    assert_eq!(query_meas_id(&download_url), attempt_ids[0].to_string());
    assert_eq!(query_meas_id(&upload_url), attempt_ids[1].to_string());

    for id in attempt_ids {
        let url = build_request_url(Direction::Download, 1, id);
        let encoded_id = query_meas_id(&url);
        assert!(!encoded_id.is_empty());
        assert!(encoded_id.chars().all(|character| character.is_ascii_digit()));
        assert_ne!(encoded_id, "0");
    }
}

#[test]
fn retry_policy_allows_initial_attempt_plus_two_retries_only() {
    let policy = RetryPolicy::default();

    assert_eq!(
        policy.decide(429, Some("1"), 0),
        RetryDecision::Retry { delay_secs: 1 }
    );
    assert_eq!(
        policy.decide(429, Some("1"), 1),
        RetryDecision::Retry { delay_secs: 1 }
    );
    assert_eq!(policy.decide(429, Some("1"), 2), RetryDecision::Abort);
    assert_eq!(policy.decide(429, Some("1"), 3), RetryDecision::Abort);
}

#[test]
fn retry_after_decimal_seconds_are_honored_only_from_one_through_thirty() {
    let policy = RetryPolicy::default();

    for (header, delay_secs) in [("1", 1), ("17", 17), ("30", 30)] {
        assert_eq!(
            policy.decide(429, Some(header), 0),
            RetryDecision::Retry { delay_secs }
        );
    }

    assert_eq!(
        policy.decide(429, Some("31"), 0),
        RetryDecision::Abort
    );
}

#[test]
fn invalid_or_missing_retry_after_uses_one_then_two_second_fallback() {
    let policy = RetryPolicy::default();

    assert_eq!(
        policy.decide(429, None, 0),
        RetryDecision::Retry { delay_secs: 1 }
    );
    assert_eq!(
        policy.decide(429, Some("malformed"), 1),
        RetryDecision::Retry { delay_secs: 2 }
    );
    assert_eq!(
        policy.decide(429, Some("0"), 0),
        RetryDecision::Retry { delay_secs: 1 }
    );
}

#[test]
fn non_429_responses_are_never_retried() {
    let policy = RetryPolicy::default();

    for status in [200, 400, 500, 503] {
        assert_eq!(
            policy.decide(status, Some("1"), 0),
            RetryDecision::NoRetry,
            "status {status} must not be retried"
        );
    }
}

#[test]
fn shared_request_gate_spaces_starts_and_propagates_later_429_deadlines_without_sleeping() {
    let mut gate = RequestGateState::default();

    let first_start = gate.reserve_start_ms(1_000);
    assert_eq!(first_start, 1_000);

    let second_start = gate.reserve_start_ms(1_001);
    assert!(second_start >= first_start + 250);

    let retry_deadline = second_start + 500;
    gate.extend_retry_deadline_ms(retry_deadline);
    let worker_released_after_429 = gate.reserve_start_ms(second_start + 1);
    assert!(worker_released_after_429 >= retry_deadline);

    let following_worker = gate.reserve_start_ms(worker_released_after_429 + 1);
    assert!(following_worker >= worker_released_after_429 + 250);

    gate.extend_retry_deadline_ms(retry_deadline - 1);
    let after_earlier_deadline = gate.reserve_start_ms(following_worker + 1);
    assert!(after_earlier_deadline >= following_worker + 250);
}

#[test]
fn download_sample_is_valid_only_when_body_length_exactly_matches_request() {
    let requested = 5;

    assert!(!is_valid_download_sample(requested, &[1, 2, 3, 4]));
    assert!(is_valid_download_sample(requested, &[1, 2, 3, 4, 5]));
    assert!(!is_valid_download_sample(requested, &[1, 2, 3, 4, 5, 6]));
}

#[test]
fn upload_helper_emits_exactly_requested_bytes_when_buffer_is_larger() {
    let requested = 9;
    let byte_ctr = Arc::new(AtomicUsize::new(0));
    let total_uploaded_counter = Arc::new(AtomicUsize::new(0));
    let exit_signal = Arc::new(AtomicBool::new(false));
    let mut helper = UploadHelper {
        bytes_to_send: requested,
        byte_ctr: Arc::clone(&byte_ctr),
        total_uploaded_counter: Arc::clone(&total_uploaded_counter),
        exit_signal,
    };

    let mut oversized_buffer = [0u8; 32];
    let first_read = helper.read(&mut oversized_buffer).unwrap();
    assert_eq!(first_read, requested);
    assert!(oversized_buffer[..first_read].iter().all(|byte| *byte == 1));
    assert_eq!(byte_ctr.load(Ordering::SeqCst), requested);
    assert_eq!(total_uploaded_counter.load(Ordering::SeqCst), requested);

    let second_read = helper.read(&mut oversized_buffer).unwrap();
    assert_eq!(second_read, 0);
    assert_eq!(byte_ctr.load(Ordering::SeqCst), requested);
    assert_eq!(total_uploaded_counter.load(Ordering::SeqCst), requested);
}

#[test]
fn fixed_utc_timestamp_formats_every_multiline_output_line() {
    let timestamp: DateTime<Utc> = DateTime::parse_from_rfc3339("2026-09-12T01:02:03.456Z")
        .unwrap()
        .with_timezone(&Utc);
    let message = "Download: 8.00 mb/s\n+----------------+\n| UP | 8.00 mb/s |\n+----------------+";
    let prefix = "[2026-09-12T01:02:03.456Z] ";

    let formatted = format_timestamped_lines(timestamp, message);
    let expected = format!(
        "{prefix}Download: 8.00 mb/s\n{prefix}+----------------+\n{prefix}| UP | 8.00 mb/s |\n{prefix}+----------------+"
    );

    assert_eq!(formatted, expected);
    assert_eq!(formatted.lines().count(), message.lines().count());
    assert!(formatted.lines().all(|line| line.starts_with(prefix)));
}

#[test]
fn zero_valid_samples_in_requested_direction_are_nonzero_without_success_table() {
    assert_nonzero_without_success_table(classify_direction_outcome(
        Direction::Download,
        &[],
        &[1],
    ));
    assert_nonzero_without_success_table(classify_direction_outcome(
        Direction::Upload,
        &[1],
        &[],
    ));
}

#[test]
fn both_direction_success_requires_at_least_one_valid_sample_from_each_direction() {
    assert_nonzero_without_success_table(classify_direction_outcome(
        Direction::Both,
        &[1],
        &[],
    ));
    assert_nonzero_without_success_table(classify_direction_outcome(
        Direction::Both,
        &[],
        &[1],
    ));

    assert_eq!(
        classify_direction_outcome(Direction::Download, &[1], &[0]),
        DirectionOutcome::SuccessTable
    );
    assert_eq!(
        classify_direction_outcome(Direction::Upload, &[0], &[1]),
        DirectionOutcome::SuccessTable
    );
    assert_eq!(
        classify_direction_outcome(Direction::Both, &[1], &[1]),
        DirectionOutcome::SuccessTable
    );
}

#[test]
fn test_get_appropriate_byte_unit() {
    assert_eq!(
        get_appropriate_byte_unit(100),
        ("100.00  B".to_string(), "800.00  b".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1015),
        ("1015.00  B".to_string(), "8.12 kb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(2048),
        ("2.00 KB".to_string(), "16.00 kb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1048576),
        ("1.00 MB".to_string(), "8.00 mb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1073741824),
        ("1.00 GB".to_string(), "8.00 gb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1099511627776),
        ("1.00 TB".to_string(), "8.00 tb".to_string())
    );

    assert_eq!(
        get_appropriate_byte_unit(1023),
        ("1023.00  B".to_string(), "8.18 kb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1024),
        ("1.00 KB".to_string(), "8.00 kb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(12939428),
        ("12.34 MB".to_string(), "98.72 mb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(814811),
        ("795.71 KB".to_string(), "6.37 mb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1024 * 1024),
        ("1.00 MB".to_string(), "8.00 mb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1024 * 1024 * 1024),
        ("1.00 GB".to_string(), "8.00 gb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1024 * 1024 * 1024 * 1024),
        ("1.00 TB".to_string(), "8.00 tb".to_string())
    );
    assert_eq!(
        get_appropriate_byte_unit(1024 * 1024 * 1024 * 1024 * 1024),
        ("1024.00 TB".to_string(), "8.19 pb".to_string())
    );
}

const LOCAL_HTTP_ACCEPT_TIMEOUT: Duration = Duration::from_secs(5);
const LOCAL_HTTP_SOCKET_TIMEOUT: Duration = Duration::from_secs(2);
const LOCAL_HTTP_MAX_HEADER_BYTES: usize = 64 * 1024;

struct RecordedHttpRequest {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl RecordedHttpRequest {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(header_name, _)| header_name.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    fn query_value(&self, name: &str) -> Option<&str> {
        let query = self.target.split_once('?')?.1;
        query.split('&').find_map(|part| {
            let (key, value) = part.split_once('=')?;
            (key == name).then_some(value)
        })
    }
}

struct LocalHttpResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

fn local_http_response(status: u16, body: &[u8], retry_after: Option<&str>) -> LocalHttpResponse {
    let mut headers = Vec::new();
    if let Some(retry_after) = retry_after {
        headers.push(("Retry-After".to_string(), retry_after.to_string()));
    }

    LocalHttpResponse {
        status,
        headers,
        body: body.to_vec(),
    }
}

struct LocalHttpServer {
    base_url: String,
    join_handle: Option<JoinHandle<Vec<RecordedHttpRequest>>>,
}

impl LocalHttpServer {
    fn finish(mut self) -> Vec<RecordedHttpRequest> {
        self.join_handle
            .take()
            .expect("local HTTP server join handle must exist")
            .join()
            .expect("local HTTP server thread must finish")
    }
}

impl Drop for LocalHttpServer {
    fn drop(&mut self) {
        if let Some(join_handle) = self.join_handle.take() {
            let _ = join_handle.join();
        }
    }
}

fn spawn_local_http_server<F>(
    expected_connections: usize,
    response_for: F,
) -> LocalHttpServer
where
    F: Fn(usize, &RecordedHttpRequest) -> LocalHttpResponse + Send + 'static,
{
    assert!(expected_connections > 0);

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback test server");
    listener
        .set_nonblocking(true)
        .expect("configure loopback listener polling");
    let base_url = format!(
        "http://127.0.0.1:{}",
        listener.local_addr().expect("read loopback listener address").port()
    );

    let join_handle = std::thread::spawn(move || {
        let deadline = Instant::now() + LOCAL_HTTP_ACCEPT_TIMEOUT;
        let mut requests = Vec::with_capacity(expected_connections);

        for connection_index in 0..expected_connections {
            let mut stream = accept_local_http_connection(&listener, deadline);
            stream
                .set_read_timeout(Some(LOCAL_HTTP_SOCKET_TIMEOUT))
                .expect("set local HTTP read timeout");
            stream
                .set_write_timeout(Some(LOCAL_HTTP_SOCKET_TIMEOUT))
                .expect("set local HTTP write timeout");

            let request = read_local_http_request(&mut stream);
            let response = response_for(connection_index, &request);
            write_local_http_response(&mut stream, response);
            requests.push(request);
        }

        assert_eq!(
            requests.len(),
            expected_connections,
            "local HTTP server must observe the exact connection count"
        );
        requests
    });

    LocalHttpServer {
        base_url,
        join_handle: Some(join_handle),
    }
}

fn accept_local_http_connection(listener: &TcpListener, deadline: Instant) -> TcpStream {
    loop {
        match listener.accept() {
            Ok((stream, _peer)) => return stream,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) =>
            {
                if Instant::now() >= deadline {
                    panic!("timed out waiting for local HTTP connection");
                }
                std::thread::yield_now();
            }
            Err(error) => panic!("local HTTP accept failed: {error}"),
        }
    }
}

fn read_local_http_request(stream: &mut TcpStream) -> RecordedHttpRequest {
    let mut raw_request = Vec::new();
    let header_end = loop {
        if let Some(header_start) = raw_request
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
        {
            break header_start + 4;
        }

        let mut chunk = [0u8; 4096];
        let read = stream
            .read(&mut chunk)
            .expect("read local HTTP request headers");
        if read == 0 {
            panic!("local HTTP peer closed before request headers");
        }
        raw_request.extend_from_slice(&chunk[..read]);
        assert!(
            raw_request.len() <= LOCAL_HTTP_MAX_HEADER_BYTES,
            "local HTTP request headers must remain bounded"
        );
    };

    let header_text = std::str::from_utf8(&raw_request[..header_end - 4])
        .expect("local HTTP request headers must be UTF-8");
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().expect("local HTTP request line");
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts
        .next()
        .expect("local HTTP request method")
        .to_string();
    let target = request_parts
        .next()
        .expect("local HTTP request target")
        .to_string();

    let headers = lines
        .filter(|line| !line.is_empty())
        .map(|line| {
            let (name, value) = line
                .split_once(':')
                .expect("local HTTP header must contain a colon");
            (name.to_ascii_lowercase(), value.trim().to_string())
        })
        .collect::<Vec<_>>();

    let content_length = headers
        .iter()
        .find(|(name, _)| name == "content-length")
        .map(|(_, value)| {
            value
                .parse::<usize>()
                .expect("local HTTP Content-Length must be an integer")
        })
        .unwrap_or(0);

    let mut body = raw_request[header_end..].to_vec();
    while body.len() < content_length {
        let mut chunk = [0u8; 4096];
        let read = stream
            .read(&mut chunk)
            .expect("read local HTTP request body");
        if read == 0 {
            panic!("local HTTP peer closed before Content-Length bytes");
        }
        body.extend_from_slice(&chunk[..read]);
    }
    body.truncate(content_length);

    RecordedHttpRequest {
        method,
        target,
        headers,
        body,
    }
}

fn write_local_http_response(stream: &mut TcpStream, response: LocalHttpResponse) {
    let reason = match response.status {
        200 => "OK",
        429 => "Too Many Requests",
        503 => "Service Unavailable",
        _ => "Test Response",
    };
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: close\r\n",
        response.status,
        reason,
        response.body.len()
    );
    for (name, value) in response.headers {
        head.push_str(&name);
        head.push_str(": ");
        head.push_str(&value);
        head.push_str("\r\n");
    }
    head.push_str("\r\n");

    stream
        .write_all(head.as_bytes())
        .expect("write local HTTP response headers");
    stream
        .write_all(&response.body)
        .expect("write local HTTP response body");
    stream.flush().expect("flush local HTTP response");
}

fn local_http_agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(true)
        .proxy(None)
        .timeout_global(Some(LOCAL_HTTP_SOCKET_TIMEOUT))
        .build()
        .into()
}

#[test]
fn execute_with_retry_uses_new_ids_and_retry_after_then_fallback_delays() {
    let attempt_count = Arc::new(AtomicUsize::new(0));
    let attempt_ids = Arc::new(Mutex::new(Vec::new()));
    let sleep_log = Arc::new(Mutex::new(Vec::new()));

    let attempt_count_for_closure = Arc::clone(&attempt_count);
    let attempt_ids_for_closure = Arc::clone(&attempt_ids);
    let sleep_log_for_closure = Arc::clone(&sleep_log);
    let result = execute_with_retry(
        RetryPolicy::default(),
        move |meas_id| {
            attempt_ids_for_closure.lock().unwrap().push(meas_id);
            match attempt_count_for_closure.fetch_add(1, Ordering::SeqCst) {
                0 => Err(AttemptFailure::RateLimited(Some("1".to_string()))),
                1 => Err(AttemptFailure::RateLimited(None)),
                2 => Ok(TransferSample {
                    bytes: 4,
                    bytes_per_second: 4,
                }),
                _ => panic!("retry state machine must not perform a fourth attempt"),
            }
        },
        move |delay_secs| {
            sleep_log_for_closure.lock().unwrap().push(delay_secs);
        },
    );

    let sample = match result {
        Ok(sample) => sample,
        Err(_) => panic!("scripted retries must eventually return the success sample"),
    };
    let attempt_ids = attempt_ids.lock().unwrap().clone();
    let sleep_log = sleep_log.lock().unwrap().clone();

    assert_eq!(attempt_count.load(Ordering::SeqCst), 3);
    assert_eq!(attempt_ids.len(), 3);
    assert!(attempt_ids.iter().all(|meas_id| *meas_id != 0));
    assert_eq!(attempt_ids.iter().copied().collect::<HashSet<_>>().len(), 3);
    assert_eq!(sleep_log, vec![1, 2]);
    assert_eq!(sample.bytes, 4);
    assert_eq!(sample.bytes_per_second, 4);
}

#[test]
fn execute_with_retry_stops_after_two_retries_and_returns_rate_limited() {
    let attempt_count = Arc::new(AtomicUsize::new(0));
    let sleep_log = Arc::new(Mutex::new(Vec::new()));
    let attempt_count_for_closure = Arc::clone(&attempt_count);
    let sleep_log_for_closure = Arc::clone(&sleep_log);

    let result = execute_with_retry(
        RetryPolicy::default(),
        move |_meas_id| {
            attempt_count_for_closure.fetch_add(1, Ordering::SeqCst);
            Err(AttemptFailure::RateLimited(Some("1".to_string())))
        },
        move |delay_secs| {
            sleep_log_for_closure.lock().unwrap().push(delay_secs);
        },
    );

    let sleep_log = sleep_log.lock().unwrap().clone();
    assert!(matches!(result, Err(AttemptFailure::RateLimited(_))));
    assert_eq!(attempt_count.load(Ordering::SeqCst), 3);
    assert_eq!(sleep_log, vec![1, 2]);
}

#[test]
fn execute_with_retry_returns_non_429_failure_without_sleep_or_retry() {
    let attempt_count = Arc::new(AtomicUsize::new(0));
    let sleep_log = Arc::new(Mutex::new(Vec::new()));
    let attempt_count_for_closure = Arc::clone(&attempt_count);
    let sleep_log_for_closure = Arc::clone(&sleep_log);

    let result = execute_with_retry(
        RetryPolicy::default(),
        move |_meas_id| {
            attempt_count_for_closure.fetch_add(1, Ordering::SeqCst);
            Err(AttemptFailure::HttpStatus(503))
        },
        move |delay_secs| {
            sleep_log_for_closure.lock().unwrap().push(delay_secs);
        },
    );

    let sleep_log = sleep_log.lock().unwrap().clone();
    assert!(matches!(result, Err(AttemptFailure::HttpStatus(503))));
    assert_eq!(attempt_count.load(Ordering::SeqCst), 1);
    assert!(sleep_log.is_empty());
}

#[test]
fn execute_with_retry_returns_transport_failure_without_retry() {
    let attempt_count = Arc::new(AtomicUsize::new(0));
    let sleep_log = Arc::new(Mutex::new(Vec::new()));
    let attempt_count_for_closure = Arc::clone(&attempt_count);
    let sleep_log_for_closure = Arc::clone(&sleep_log);

    let result = execute_with_retry(
        RetryPolicy::default(),
        move |_meas_id| {
            attempt_count_for_closure.fetch_add(1, Ordering::SeqCst);
            Err(AttemptFailure::Transport)
        },
        move |delay_secs| {
            sleep_log_for_closure.lock().unwrap().push(delay_secs);
        },
    );

    let sleep_log = sleep_log.lock().unwrap().clone();
    assert!(matches!(result, Err(AttemptFailure::Transport)));
    assert_eq!(attempt_count.load(Ordering::SeqCst), 1);
    assert!(sleep_log.is_empty());
}

#[test]
fn download_once_returns_sample_and_records_exact_local_query() {
    let server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(200, &[1, 2, 3, 4], None)
    });
    let agent = local_http_agent();
    let meas_id = next_meas_id();
    assert_ne!(meas_id, 0);
    let result = download_once(&agent, &server.base_url, 4, meas_id);
    let requests = server.finish();

    let sample = match result {
        Ok(sample) => sample,
        Err(_) => panic!("exact local download must return a sample"),
    };
    let meas_id_text = meas_id.to_string();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "GET");
    assert_eq!(requests[0].query_value("bytes"), Some("4"));
    assert_eq!(requests[0].query_value("measId"), Some(meas_id_text.as_str()));
    assert_eq!(sample.bytes, 4);
}

#[test]
fn download_once_preserves_retry_after_from_local_429() {
    let server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(429, &[], Some("7"))
    });
    let agent = local_http_agent();
    let result = download_once(&agent, &server.base_url, 4, next_meas_id());
    let requests = server.finish();

    match result {
        Err(AttemptFailure::RateLimited(retry_after)) => {
            assert_eq!(retry_after.as_deref(), Some("7"));
        }
        _ => panic!("local 429 must remain a rate-limited failure"),
    }
    assert_eq!(requests.len(), 1);
}

#[test]
fn download_once_rejects_short_local_body_with_expected_and_actual_lengths() {
    let server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(200, &[1, 2, 3], None)
    });
    let agent = local_http_agent();
    let result = download_once(&agent, &server.base_url, 4, next_meas_id());
    let requests = server.finish();

    match result {
        Err(AttemptFailure::InvalidBodyLength { expected, actual }) => {
            assert_eq!(expected, 4);
            assert_eq!(actual, 3);
        }
        _ => panic!("short local download must report its body lengths"),
    }
    assert_eq!(requests.len(), 1);
}

#[test]
fn download_once_reports_non_429_local_status_without_retry_classification() {
    let server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(503, &[], None)
    });
    let agent = local_http_agent();
    let result = download_once(&agent, &server.base_url, 4, next_meas_id());
    let requests = server.finish();

    assert!(matches!(result, Err(AttemptFailure::HttpStatus(503))));
    assert_eq!(requests.len(), 1);
}

#[test]
fn upload_once_sends_exact_content_length_and_body_to_local_server() {
    let server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(200, b"ok", None)
    });
    let agent = local_http_agent();
    let meas_id = next_meas_id();
    assert_ne!(meas_id, 0);
    let result = upload_once(&agent, &server.base_url, 9, meas_id);
    let requests = server.finish();

    let sample = match result {
        Ok(sample) => sample,
        Err(_) => panic!("local upload success must return a sample"),
    };
    let meas_id_text = meas_id.to_string();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "POST");
    assert_eq!(requests[0].query_value("measId"), Some(meas_id_text.as_str()));
    assert_eq!(requests[0].header("content-length"), Some("9"));
    assert_eq!(requests[0].body, vec![1u8; 9]);
    assert_eq!(sample.bytes, 9);
}

#[test]
fn upload_once_preserves_retry_after_from_local_429() {
    let server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(429, &[], Some("11"))
    });
    let agent = local_http_agent();
    let result = upload_once(&agent, &server.base_url, 9, next_meas_id());
    let requests = server.finish();

    match result {
        Err(AttemptFailure::RateLimited(retry_after)) => {
            assert_eq!(retry_after.as_deref(), Some("11"));
        }
        _ => panic!("local upload 429 must remain a rate-limited failure"),
    }
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].header("content-length"), Some("9"));
    assert_eq!(requests[0].body, vec![1u8; 9]);
}
