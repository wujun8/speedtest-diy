use super::*;
use chrono::{DateTime, Utc};
use std::collections::HashSet;
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

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
