use std::{collections::HashMap, sync::Arc};
use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    response::IntoResponse,
    routing::{get, get_service},
    Router,
    extract::State,
};
use tower_http::services::{ServeDir, ServeFile};
use axum::http::StatusCode;

use serde::{Serialize, Deserialize};
use tokio::sync::Mutex;

#[derive(Default)]
struct Rooms {
    inner: Mutex<HashMap<String, Arc<Room>>>,
}

struct Room {
    id: String,
    messages: Mutex<HashMap<String, Vec<String>>>,
}

impl Room {
    fn new(id: String) -> Self {
        Self {
            id,
            messages: Mutex::new(HashMap::new()),
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "type")]
enum ClientMsg {
    #[serde(rename = "newroom")]
    NewRoom { socketId: Option<String> },
    #[serde(rename = "fetchRoom")]
    FetchRoom { id: String, socketId: Option<String> },
    #[serde(rename = "keyPress")]
    KeyPress { key: String, cursorPos: Option<usize> },
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    let rooms = Arc::new(Rooms::default());
    let static_files = get_service(ServeDir::new("gui")).handle_error(|_| async {
        StatusCode::INTERNAL_SERVER_ERROR
    });
    let index = get_service(ServeFile::new("gui/index.html")).handle_error(|_| async {
        StatusCode::INTERNAL_SERVER_ERROR
    });

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .with_state(rooms.clone())
        .route("/health", get(|| async { "ok" }))
        .nest_service("/gui", static_files)
        .fallback_service(index);

    axum::Server::bind(&"0.0.0.0:8090".parse().unwrap())
        .serve(app.into_make_service())
        .await
        .unwrap();
}

async fn ws_handler(ws: WebSocketUpgrade, State(rooms): State<Arc<Rooms>>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, rooms))
}

async fn handle_socket(mut socket: WebSocket, rooms: Arc<Rooms>) {
    while let Some(Ok(msg)) = socket.recv().await {
        if let Message::Text(text) = msg {
            if let Ok(val) = serde_json::from_str::<ClientMsg>(&text) {
                match val {
                    ClientMsg::NewRoom { .. } => {
                        // simplified: just echo back
                        let _ = socket.send(Message::Text("{\"type\":\"roomCreated\"}".into())).await;
                    }
                    ClientMsg::FetchRoom { id, .. } => {
                        let mut map = rooms.inner.lock().await;
                        map.entry(id.clone()).or_insert_with(|| Arc::new(Room::new(id)));
                        drop(map);
                        let _ = socket.send(Message::Text("{\"type\":\"gotRoom\"}".into())).await;
                    }
                    ClientMsg::KeyPress { key, .. } => {
                        let _ = socket.send(Message::Text(format!("{{\"type\":\"keyPressEcho\",\"key\":\"{}\"}}", key))).await;
                    }
                }
            }
        }
    }
}
