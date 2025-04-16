use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::{
    accept_async, tungstenite::Error as WsError, tungstenite::protocol::Message,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Create a TCP listener bound to localhost:8080
    let addr = "127.0.0.1:8080";
    let listener = TcpListener::bind(addr).await?;
    println!("WebSocket server listening on ws://{}", addr);

    // Accept incoming connections
    while let Ok((stream, addr)) = listener.accept().await {
        println!("New connection from: {}", addr);

        // Handle each connection in a separate task
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream).await {
                eprintln!("Error handling connection: {}", e);
            }
        });
    }

    Ok(())
}

async fn handle_connection(stream: TcpStream) -> Result<(), WsError> {
    // Upgrade TCP connection to WebSocket
    let ws_stream = accept_async(stream).await?;
    println!("WebSocket connection established");

    // Split stream for concurrent reading and writing
    let (mut ws_sender, mut ws_receiver) = ws_stream.split();

    // Echo incoming messages
    while let Some(msg) = ws_receiver.next().await {
        let msg = msg?;

        match msg {
            Message::Text(text) => {
                println!("Received text message: {}", text);
                ws_sender.send(Message::Text(text)).await?;
            }
            Message::Binary(data) => {
                println!("Received binary message, {} bytes", data.len());
                ws_sender.send(Message::Binary(data)).await?;
            }
            Message::Ping(data) => {
                println!("Received ping");
                ws_sender.send(Message::Pong(data)).await?;
            }
            Message::Pong(_) => {
                println!("Received pong");
            }
            Message::Close(_) => {
                println!("Client disconnected");
                break;
            }
            _ => {} // Other message types
        }
    }

    println!("WebSocket connection closed");
    Ok(())
}
