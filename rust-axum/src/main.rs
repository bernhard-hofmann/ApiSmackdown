use axum::{Router, routing::get};

// The "rust-tuned" target builds this same code with the `tuned` profile and
// the `mimalloc` feature (see Cargo.toml).
#[cfg(feature = "mimalloc")]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[tokio::main]
async fn main() {
    let port = std::env::var("PORT").unwrap_or_else(|_| "3004".into());
    let app = Router::new().route("/", get(|| async { "Rust    greets the world!" }));

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.unwrap();
    println!("Rust (axum) listening at http://localhost:{port}");
    axum::serve(listener, app).await.unwrap();
}
