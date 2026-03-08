use clap::{Parser, Subcommand};
use anyhow::Result;
use reqwest::Client;
use scraper::{Html, Selector};
use url::Url;

#[derive(Parser)]
#[command(name = "argiope")]
#[command(about = "A web utility tool", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Check links on a page
    Check {
        /// URL to check
        url: String,
    },
    /// Download images from a page
    Images {
        /// URL to download from
        url: String,
    },
    /// Browse image library
    Library {
        /// Path to library
        path: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let client = Client::new();

    match &cli.command {
        Commands::Check { url } => {
            println!("Checking links for {}", url);
            let res = client.get(url).send().await?.text().await?;
            let document = Html::parse_document(&res);
            let selector = Selector::parse("a").unwrap();
            let base_url = Url::parse(url)?;
            
            for element in document.select(&selector) {
                if let Some(href) = element.value().attr("href") {
                    if let Ok(parsed) = base_url.join(href) {
                        println!("Found link: {}", parsed);
                    }
                }
            }
        }
        Commands::Images { url } => {
            println!("Downloading images from {}", url);
            let res = client.get(url).send().await?.text().await?;
            let document = Html::parse_document(&res);
            let selector = Selector::parse("img").unwrap();
            let base_url = Url::parse(url)?;

            for element in document.select(&selector) {
                if let Some(src) = element.value().attr("src") {
                    if let Ok(parsed) = base_url.join(src) {
                        println!("Found image: {}", parsed);
                    }
                }
            }
        }
        Commands::Library { path } => {
            println!("Browsing library at {}", path);
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cli_parse() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }
}
