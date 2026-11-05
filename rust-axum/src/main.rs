use axum::{Router, routing::get};

#[tokio::main]
async fn main() {
    let app = Router::new().route("/", get(|| async { "Rust    greets the world!" }));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3004").await.unwrap();
    println!("Rust (axum) listening at http://localhost:3004");
    axum::serve(listener, app).await.unwrap();
}
