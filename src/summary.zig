/// CheckSummary holds aggregate statistics for a link-check run.
pub const CheckSummary = struct {
    total_urls: usize,
    ok_count: usize,
    broken_count: usize,
    error_count: usize,
    internal_count: usize,
    external_count: usize,
    total_time_ms: u64,
    min_time_ms: u64,
    max_time_ms: u64,
};
