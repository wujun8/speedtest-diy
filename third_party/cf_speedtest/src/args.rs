use argh::FromArgs;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(FromArgs, Clone)]
/// A speedtest CLI written in Rust
pub struct UserArgs {
    /// how many download threads to use (default 8)
    #[argh(option, default = "8")]
    pub download_threads: u32,

    /// how many upload threads to use (default 8)
    #[argh(option, default = "8")]
    pub upload_threads: u32,

    /// when set, only run the download test
    #[argh(switch, short = 'd')]
    pub download_only: bool,

    /// when set, only run the upload test
    #[argh(switch, short = 'u')]
    pub upload_only: bool,

    /// the amount of bytes to download in a single request (default 10MB)
    #[argh(option, default = "10 * 1024 * 1024")]
    pub bytes_to_download: usize,

    /// the amount of bytes to upload in a single request (default 10MB)
    #[argh(option, default = "10 * 1024 * 1024")]
    pub bytes_to_upload: usize,

    /// how many seconds to run each upload/download test for (default 12)
    #[argh(option, default = "12")]
    pub test_duration_seconds: u64,
}

impl Default for UserArgs {
    fn default() -> Self {
        Self {
            download_threads: 8,
            upload_threads: 8,
            download_only: false,
            upload_only: false,
            bytes_to_download: 10 * 1024 * 1024,
            bytes_to_upload: 10 * 1024 * 1024,
            test_duration_seconds: 12,
        }
    }
}

impl UserArgs {
    pub fn validate(&self) -> Result<()> {
        if self.download_only && self.upload_only {
            return Err(Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Cannot specify both --download-only and --upload-only",
            )));
        }

        if self.bytes_to_download == 0 || self.bytes_to_upload == 0 {
            return Err(Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Byte counts must be greater than zero",
            )));
        }

        if self.download_threads == 0
            || self.download_threads > 64
            || self.upload_threads == 0
            || self.upload_threads > 64
        {
            return Err(Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Thread counts must be between 1 and 64",
            )));
        }

        Ok(())
    }
}
