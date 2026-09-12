use super::*;
use chrono::{DateTime, Utc};
use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex};
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
fn production_upload_streams_the_configured_body_without_a_request_sized_vec() {
    let source = include_str!("main.rs");

    assert!(!source.contains("let body = vec![1u8; requested_bytes]"));
    assert!(source.contains("ureq::SendBody::from_owned_reader(UploadHelper"));
    assert!(source.contains(".header(\"Content-Length\", requested_bytes.to_string())"));
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

#[test]
fn runtime_request_gate_spaces_starts_and_rechecks_a_retry_deadline_during_wait() {
    let gate = RuntimeRequestGate::new();
    let now_ms = Cell::new(0_u64);

    let first_start = gate.wait_for_start_with(|| now_ms.get(), |_| {});
    assert_eq!(first_start, 0);

    let second_start = gate.wait_for_start_with(|| now_ms.get(), |delay_ms| {
        now_ms.set(now_ms.get().saturating_add(delay_ms));
    });
    assert!(second_start >= first_start + 250);

    let retry_gate = RuntimeRequestGate::new();
    let retry_now_ms = Cell::new(0_u64);
    assert_eq!(
        retry_gate.wait_for_start_with(|| retry_now_ms.get(), |_| {}),
        0
    );

    let mut sleep_log = Vec::new();
    let retry_extended = Cell::new(false);
    let delayed_start = retry_gate.wait_for_start_with(
        || retry_now_ms.get(),
        |delay_ms| {
            sleep_log.push(delay_ms);
            if !retry_extended.replace(true) {
                retry_gate.extend_retry_deadline_ms(1_000);
            }
            retry_now_ms.set(retry_now_ms.get().saturating_add(delay_ms));
        },
    );

    assert!(delayed_start >= 1_000);
    assert!(sleep_log.len() >= 2);
    assert!(retry_extended.get());
}

#[test]
fn direction_state_counts_only_successful_samples_and_preserves_the_first_terminal_error() {
    let first_sample = TransferSample {
        bytes: 12,
        bytes_per_second: 120,
    };
    let second_sample = TransferSample {
        bytes: 7,
        bytes_per_second: 70,
    };
    let mut state = DirectionState::default();
    state.record_sample(first_sample);
    state.record_sample(second_sample);

    let snapshot = state.snapshot();
    assert_eq!(snapshot.valid_sample_count, 2);
    assert_eq!(snapshot.confirmed_bytes, 19);
    assert_eq!(snapshot.measurements, vec![first_sample, second_sample]);
    assert_eq!(snapshot.terminal_error, None);
    assert!(!state.should_stop());

    let terminal_failures = vec![
        AttemptFailure::InvalidBodyLength {
            expected: 8,
            actual: 7,
        },
        AttemptFailure::RateLimited(Some("1".to_string())),
        AttemptFailure::HttpStatus(503),
        AttemptFailure::Transport,
    ];
    for failure in terminal_failures {
        let mut failed_state = DirectionState::default();
        failed_state.record_terminal_error(failure.clone());
        let failed_snapshot = failed_state.snapshot();

        assert_eq!(failed_snapshot.valid_sample_count, 0);
        assert_eq!(failed_snapshot.confirmed_bytes, 0);
        assert!(failed_snapshot.measurements.is_empty());
        assert_eq!(failed_snapshot.terminal_error, Some(failure));
        assert!(failed_state.should_stop());
    }

    let first_error = AttemptFailure::HttpStatus(503);
    let later_error = AttemptFailure::Transport;
    state.record_terminal_error(first_error.clone());
    state.record_terminal_error(later_error);
    let terminal_snapshot = state.snapshot();
    assert_eq!(terminal_snapshot.terminal_error, Some(first_error));
    assert!(state.should_stop());
}

fn assert_direction_run_result(
    result: DirectionRunResult,
    expected_exit_code: i32,
    expected_success_table: bool,
) {
    assert_eq!(result.exit_code(), expected_exit_code);
    assert_eq!(result.has_success_table(), expected_success_table);
}

#[test]
fn direction_run_classification_distinguishes_zero_samples_errors_and_complete_success() {
    let empty_download = DirectionState::default();
    let empty_upload = DirectionState::default();

    for requested in [Direction::Download, Direction::Upload, Direction::Both] {
        assert_direction_run_result(
            classify_direction_run_result(requested, &empty_download, &empty_upload),
            3,
            false,
        );
    }

    let mut download_with_error = DirectionState::default();
    download_with_error.record_sample(TransferSample {
        bytes: 4,
        bytes_per_second: 40,
    });
    download_with_error.record_terminal_error(AttemptFailure::HttpStatus(503));
    assert_direction_run_result(
        classify_direction_run_result(Direction::Download, &download_with_error, &empty_upload),
        1,
        false,
    );

    let mut upload_with_error = DirectionState::default();
    upload_with_error.record_sample(TransferSample {
        bytes: 5,
        bytes_per_second: 50,
    });
    upload_with_error.record_terminal_error(AttemptFailure::Transport);
    assert_direction_run_result(
        classify_direction_run_result(Direction::Upload, &empty_download, &upload_with_error),
        1,
        false,
    );

    assert_direction_run_result(
        classify_direction_run_result(
            Direction::Both,
            &download_with_error,
            &upload_with_error,
        ),
        1,
        false,
    );

    let mut successful_download = DirectionState::default();
    successful_download.record_sample(TransferSample {
        bytes: 8,
        bytes_per_second: 80,
    });
    let mut successful_upload = DirectionState::default();
    successful_upload.record_sample(TransferSample {
        bytes: 9,
        bytes_per_second: 90,
    });

    assert_direction_run_result(
        classify_direction_run_result(Direction::Download, &successful_download, &empty_upload),
        0,
        true,
    );
    assert_direction_run_result(
        classify_direction_run_result(Direction::Upload, &empty_download, &successful_upload),
        0,
        true,
    );
    assert_direction_run_result(
        classify_direction_run_result(
            Direction::Both,
            &successful_download,
            &successful_upload,
        ),
        0,
        true,
    );
}

#[test]
fn worker_cycle_composes_shared_gate_and_retry_without_real_sleep() {
    let gate = RuntimeRequestGate::new();
    let now_ms = Cell::new(0_u64);
    let attempt_count = Cell::new(0_usize);
    let attempt_ids = RefCell::new(Vec::new());
    let attempt_times = RefCell::new(Vec::new());
    let sleep_log = RefCell::new(Vec::new());
    let successful_sample = TransferSample {
        bytes: 16,
        bytes_per_second: 160,
    };
    let mut state = DirectionState::default();

    let _ = run_worker_cycle(
        &mut state,
        &gate,
        |attempt_id| {
            attempt_ids.borrow_mut().push(attempt_id);
            attempt_times.borrow_mut().push(now_ms.get());
            let attempt_index = attempt_count.get();
            attempt_count.set(attempt_index + 1);
            match attempt_index {
                0 => Err(AttemptFailure::RateLimited(Some("1".to_string()))),
                1 => Ok(successful_sample),
                _ => panic!("429 followed by success must perform exactly two attempts"),
            }
        },
        || now_ms.get(),
        |delay_ms| {
            sleep_log.borrow_mut().push(delay_ms);
            now_ms.set(now_ms.get().saturating_add(delay_ms));
        },
    );

    let attempt_ids = attempt_ids.into_inner();
    let attempt_times = attempt_times.into_inner();
    let sleep_log = sleep_log.into_inner();
    let snapshot = state.snapshot();

    assert_eq!(attempt_count.get(), 2);
    assert_eq!(attempt_ids.len(), 2);
    assert!(attempt_ids.iter().all(|attempt_id| *attempt_id != 0));
    assert_eq!(
        attempt_ids.iter().copied().collect::<HashSet<_>>().len(),
        2
    );
    assert_eq!(attempt_times.len(), 2);
    assert!(attempt_times[1] >= 1_000);
    assert_eq!(sleep_log, vec![1_000]);
    assert_eq!(snapshot.valid_sample_count, 1);
    assert_eq!(snapshot.confirmed_bytes, successful_sample.bytes);
    assert_eq!(snapshot.measurements, vec![successful_sample]);
    assert_eq!(snapshot.terminal_error, None);
    assert!(!state.should_stop());
}

#[test]
fn terminal_worker_cycle_stops_future_cycles_without_issuing_more_requests() {
    let gate = RuntimeRequestGate::new();
    let now_ms = Cell::new(0_u64);
    let first_request_count = Cell::new(0_usize);
    let mut state = DirectionState::default();

    let _ = run_worker_cycle(
        &mut state,
        &gate,
        |_attempt_id| {
            first_request_count.set(first_request_count.get() + 1);
            Err(AttemptFailure::HttpStatus(503))
        },
        || now_ms.get(),
        |_delay_ms| panic!("terminal HTTP status must not sleep"),
    );

    assert_eq!(first_request_count.get(), 1);
    assert!(state.should_stop());
    let first_snapshot = state.snapshot();
    assert_eq!(first_snapshot.valid_sample_count, 0);
    assert_eq!(first_snapshot.confirmed_bytes, 0);
    assert!(first_snapshot.measurements.is_empty());
    assert_eq!(
        first_snapshot.terminal_error,
        Some(AttemptFailure::HttpStatus(503))
    );

    let second_request_count = Cell::new(0_usize);
    let _ = run_worker_cycle(
        &mut state,
        &gate,
        |_attempt_id| {
            second_request_count.set(second_request_count.get() + 1);
            Ok(TransferSample {
                bytes: 32,
                bytes_per_second: 320,
            })
        },
        || now_ms.get(),
        |_delay_ms| panic!("a stopped worker cycle must not sleep"),
    );

    assert_eq!(second_request_count.get(), 0);
    assert_eq!(state.snapshot().terminal_error, Some(AttemptFailure::HttpStatus(503)));
}

#[test]
fn retry_after_deadline_is_shared_by_two_logical_workers_in_virtual_time() {
    let gate = RuntimeRequestGate::new();
    let now_ms = Cell::new(0_u64);
    let first_worker_start = gate.wait_for_start_with(|| now_ms.get(), |_| {});
    assert_eq!(first_worker_start, 0);

    let retry_deadline_ms = 1_000;
    now_ms.set(250);
    gate.extend_retry_deadline_ms(retry_deadline_ms);

    let mut sleep_log = Vec::new();
    let second_worker_start = gate.wait_for_start_with(
        || now_ms.get(),
        |delay_ms| {
            sleep_log.push(delay_ms);
            now_ms.set(now_ms.get().saturating_add(delay_ms));
        },
    );
    let second_worker_issue_time = now_ms.get();

    assert!(second_worker_start >= retry_deadline_ms);
    assert_eq!(second_worker_issue_time, second_worker_start);
    assert!(second_worker_issue_time >= retry_deadline_ms);
    assert_eq!(sleep_log, vec![750]);
}

#[test]
fn requested_direction_maps_cli_switches_to_the_single_production_direction() {
    let mut args = UserArgs::default();
    assert_eq!(Direction::from_args(&args), Direction::Both);

    args.download_only = true;
    assert_eq!(Direction::from_args(&args), Direction::Download);

    args.download_only = false;
    args.upload_only = true;
    assert_eq!(Direction::from_args(&args), Direction::Upload);
}

#[test]
fn server_info_uses_a_fresh_nonzero_measurement_id_and_propagates_runtime_failure() {
    let agent = local_http_agent();
    let server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(200, b"server-info", None)
    });
    let result = get_download_server_info(&agent, &server.base_url);
    let requests = server.finish();

    assert!(result.is_ok());
    assert_eq!(requests.len(), 1);
    let meas_id = requests[0].query_value("measId").expect("server-info measId");
    assert!(!meas_id.is_empty());
    assert_ne!(meas_id, "0");
    assert!(meas_id.bytes().all(|byte| byte.is_ascii_digit()));

    let failing_server = spawn_local_http_server(1, |_connection_index, _request| {
        local_http_response(503, b"failure", None)
    });
    let failure = get_download_server_info(&agent, &failing_server.base_url);
    let _ = failing_server.finish();
    assert!(failure.is_err(), "server-info runtime failures must propagate");
}

#[test]
fn attempt_failure_messages_distinguish_exhausted_429_and_non_429_causes() {
    let result = execute_with_retry(
        RetryPolicy::default(),
        |_meas_id| Err(AttemptFailure::RateLimited(None)),
        |_delay_secs| {},
    );
    let rate_limited = result
        .expect_err("three rate-limited attempts must terminate")
        .to_string()
        .to_ascii_lowercase();
    let status = AttemptFailure::HttpStatus(503).to_string();
    let transport = AttemptFailure::Transport.to_string();
    let body = AttemptFailure::InvalidBodyLength {
        expected: 8,
        actual: 7,
    }
    .to_string();

    assert!(rate_limited.contains("429"));
    assert!(rate_limited.contains("retry budget exhausted"));
    assert!(status.contains("503"));
    assert!(status.to_ascii_lowercase().contains("http"));
    assert!(transport.to_ascii_lowercase().contains("transport"));
    assert!(body.contains("expected 8"));
    assert!(body.contains("actual 7"));
}

fn test_timestamp(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&Utc)
}

#[test]
fn timestamped_logger_keeps_concurrent_multiline_calls_as_whole_blocks() {
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let logger = Arc::new(ThreadSafeLogger::new(Arc::clone(&output)));
    let barrier = Arc::new(Barrier::new(3));
    let timestamp_a = test_timestamp("2026-09-12T01:02:03.456Z");
    let timestamp_b = test_timestamp("2026-09-12T01:02:04.456Z");
    let message_a = "下载: 8.00 mb/s\n┌────────────┐\n│ 上传 │ 8.00 mb/s │\n└────────────┘\n";
    let message_b = "worker-b\n┌────┐\n│ B  │\n└────┘\n";
    let expected_a = format_timestamped_lines(timestamp_a, message_a);
    let expected_b = format_timestamped_lines(timestamp_b, message_b);

    let handles: Vec<_> = [(timestamp_a, message_a), (timestamp_b, message_b)]
        .into_iter()
        .map(|(timestamp, message)| {
            let logger = Arc::clone(&logger);
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                logger.log_at(timestamp, message).unwrap();
            })
        })
        .collect();
    barrier.wait();
    for handle in handles {
        handle.join().unwrap();
    }

    let rendered = String::from_utf8(output.lock().unwrap().clone()).unwrap();
    assert!(
        rendered == format!("{expected_a}{expected_b}")
            || rendered == format!("{expected_b}{expected_a}"),
        "concurrent log calls must not interleave physical lines: {rendered:?}"
    );
}

#[test]
fn timestamped_logger_terminates_sequential_calls_with_newlines() {
    let (output, logger) = test_logger();
    let first_timestamp = test_timestamp("2026-09-12T01:02:03.456Z");
    let second_timestamp = test_timestamp("2026-09-12T01:02:04.456Z");
    let first_prefix = "[2026-09-12T01:02:03.456Z] ";
    let second_prefix = "[2026-09-12T01:02:04.456Z] ";

    logger
        .log_at(first_timestamp, "first\nfirst-tail")
        .unwrap();
    logger.log_at(second_timestamp, "second").unwrap();

    let rendered = test_output_text(&output);
    assert_eq!(
        rendered.lines().collect::<Vec<_>>(),
        vec![
            "[2026-09-12T01:02:03.456Z] first",
            "[2026-09-12T01:02:03.456Z] first-tail",
            "[2026-09-12T01:02:04.456Z] second",
        ]
    );
    assert!(rendered.ends_with('\n'));
    assert!(rendered.lines().all(|line| {
        line.matches(first_prefix).count() + line.matches(second_prefix).count() == 1
    }));
    assert!(rendered.contains("[2026-09-12T01:02:03.456Z] first\n"));
    assert!(rendered.contains("[2026-09-12T01:02:04.456Z] second\n"));
    assert!(!rendered.contains("first[2026-09-12T01:02:04.456Z] second"));
}

#[test]
fn cancelled_runtime_gate_wait_returns_without_issuing_request_or_spinning() {
    let gate = Arc::new(RuntimeRequestGate::new());
    let first_start = gate.wait_for_start_with(|| 0, |_| {});
    assert_eq!(first_start, 0);

    let state = Arc::new(DirectionState::default());
    let now_ms = Arc::new(AtomicU64::new(0));
    let sleep_count = Arc::new(AtomicUsize::new(0));
    let request_count = Arc::new(AtomicUsize::new(0));
    let (done_sender, done_receiver) = std::sync::mpsc::sync_channel(1);

    let gate_for_worker = Arc::clone(&gate);
    let state_for_worker = Arc::clone(&state);
    let now_for_worker = Arc::clone(&now_ms);
    let sleep_count_for_worker = Arc::clone(&sleep_count);
    let request_count_for_worker = Arc::clone(&request_count);
    let worker = std::thread::spawn(move || {
        let mut now = || now_for_worker.load(Ordering::SeqCst);
        let state_for_sleeper = Arc::clone(&state_for_worker);
        let sleep_count_for_sleeper = Arc::clone(&sleep_count_for_worker);
        let mut sleeper = move |_delay_ms: u64| {
            if sleep_count_for_sleeper.fetch_add(1, Ordering::SeqCst) == 0 {
                state_for_sleeper.stop_normally();
            }
            // Deliberately do not advance virtual time: cancellation must win.
        };
        let state_for_cancel = Arc::clone(&state_for_worker);
        let mut cancel = move || state_for_cancel.should_stop();

        let reserved_start = gate_for_worker.wait_for_start_with_cancel(
            &mut now,
            &mut sleeper,
            &mut cancel,
        );
        if reserved_start.is_some() {
            request_count_for_worker.fetch_add(1, Ordering::SeqCst);
        }
        done_sender
            .send(reserved_start)
            .expect("cancellation result receiver must remain available");
    });

    let reserved_start = match done_receiver.recv_timeout(Duration::from_millis(250)) {
        Ok(reserved_start) => reserved_start,
        Err(error) => {
            drop(worker);
            panic!("cancelled gate wait must return promptly: {error}");
        }
    };
    worker
        .join()
        .expect("cancelled gate worker thread must finish");

    assert_eq!(reserved_start, None);
    assert_eq!(request_count.load(Ordering::SeqCst), 0);
    assert_eq!(sleep_count.load(Ordering::SeqCst), 1);
}

#[test]
fn zero_duration_skips_network_preamble_but_positive_duration_runs_it() {
    let mut args = UserArgs::default();
    args.test_duration_seconds = 0;
    assert!(!should_run_network_preamble(&args));

    args.test_duration_seconds = 1;
    assert!(should_run_network_preamble(&args));
}

#[test]
fn direction_runner_attempts_positive_cycles_but_zero_cycles_record_no_sample() {
    let gate = RuntimeRequestGate::new();
    let now_ms = Cell::new(0_u64);
    let empty_state = DirectionState::default();
    let zero_result = run_direction_for_cycles(
        Direction::Download,
        0,
        &empty_state,
        &gate,
        |_| panic!("zero cycles must not issue a request"),
        || now_ms.get(),
        |delay_ms| now_ms.set(now_ms.get().saturating_add(delay_ms)),
    );
    assert_eq!(zero_result, DirectionRunResult::NoValidSamples);
    assert_eq!(empty_state.snapshot().valid_sample_count, 0);

    let positive_state = DirectionState::default();
    let positive_result = run_direction_for_cycles(
        Direction::Download,
        1,
        &positive_state,
        &gate,
        |attempt_id| {
            assert_ne!(attempt_id, 0);
            Ok(TransferSample {
                bytes: 16,
                bytes_per_second: 160,
            })
        },
        || now_ms.get(),
        |delay_ms| now_ms.set(now_ms.get().saturating_add(delay_ms)),
    );
    assert_eq!(positive_result, DirectionRunResult::SuccessTable);
    assert_eq!(positive_state.snapshot().valid_sample_count, 1);
}

fn test_output_text(output: &Arc<Mutex<Vec<u8>>>) -> String {
    String::from_utf8(output.lock().unwrap().clone()).unwrap()
}

fn test_logger() -> (Arc<Mutex<Vec<u8>>>, ThreadSafeLogger<Vec<u8>>) {
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let logger = ThreadSafeLogger::new(Arc::clone(&output));
    (output, logger)
}

fn sampled_snapshot(bytes: usize, bytes_per_second: usize) -> DirectionStateSnapshot {
    let state = DirectionState::default();
    state.record_sample(TransferSample {
        bytes,
        bytes_per_second,
    });
    state.snapshot()
}

#[test]
fn run_program_renders_a_table_only_for_complete_requested_directions() {
    let args = UserArgs::default();
    let download_snapshot = sampled_snapshot(8, 80);
    let upload_snapshot = sampled_snapshot(9, 90);
    let (output, logger) = test_logger();

    let exit_code = run_program(&args, &download_snapshot, &upload_snapshot, &logger);

    assert_eq!(exit_code, 0);
    let rendered = test_output_text(&output);
    assert!(rendered.contains("Median"));
    assert!(rendered.contains("90th pctile"));
}

#[test]
fn run_program_returns_semantic_failure_codes_without_rendering_a_success_table() {
    let empty_download = DirectionState::default();
    let empty_upload = DirectionState::default();
    let empty_download_snapshot = empty_download.snapshot();
    let empty_upload_snapshot = empty_upload.snapshot();
    let mut args = UserArgs::default();
    let (zero_output, zero_logger) = test_logger();

    let zero_code = run_program(
        &args,
        &empty_download_snapshot,
        &empty_upload_snapshot,
        &zero_logger,
    );
    assert_eq!(zero_code, 3);
    assert!(!test_output_text(&zero_output).contains("90th pctile"));

    let terminal_download = DirectionState::default();
    terminal_download.record_sample(TransferSample {
        bytes: 4,
        bytes_per_second: 40,
    });
    terminal_download.record_terminal_error(AttemptFailure::HttpStatus(503));
    let terminal_snapshot = terminal_download.snapshot();
    args.download_only = true;
    let (terminal_output, terminal_logger) = test_logger();

    let terminal_code = run_program(
        &args,
        &terminal_snapshot,
        &empty_upload_snapshot,
        &terminal_logger,
    );
    assert_eq!(terminal_code, 1);
    let rendered = test_output_text(&terminal_output);
    assert!(rendered.contains("503"));
    assert!(!rendered.contains("90th pctile"));
}

#[test]
fn run_program_rejects_invalid_thread_or_byte_arguments_with_exit_two() {
    let download = DirectionState::default().snapshot();
    let upload = DirectionState::default().snapshot();
    let (output, logger) = test_logger();
    let mut args = UserArgs::default();
    args.download_threads = 0;
    assert_eq!(run_program(&args, &download, &upload, &logger), 2);

    args = UserArgs::default();
    args.bytes_to_upload = 0;
    assert_eq!(run_program(&args, &download, &upload, &logger), 2);
    assert!(!test_output_text(&output).contains("90th pctile"));
}
