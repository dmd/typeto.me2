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

use serde::{Deserialize, Serialize};
use serde_json::json;
use rand::{RngCore, thread_rng};
use tokio::sync::Mutex;

#[derive(Default)]
struct Rooms {
    inner: Mutex<HashMap<String, Arc<Room>>>,
}

struct Room {
    id: String,
    messages: Mutex<HashMap<String, Vec<String>>>,
}

fn random_hex(len: usize) -> String {
    assert!(len % 2 == 0, "len must be even");
    let mut rng = thread_rng();
    let mut bytes = vec![0u8; len / 2];
    rng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

impl Room {
    fn new(id: String) -> Self {
        Self {
            id,
            messages: Mutex::new(HashMap::new()),
        }
    }

    async fn join(&self, socket_id: String) {
        let mut msgs = self.messages.lock().await;
        msgs.entry(socket_id).or_insert_with(|| vec![String::new()]);
    }

    async fn render(&self, socket_id: &str) -> RoomView {
        let msgs = self.messages.lock().await.clone();
        let participants = msgs.len();
        let other_ids: Vec<String> = msgs
            .keys()
            .filter(|id| *id != socket_id)
            .cloned()
            .collect();
        let their_id = other_ids.get(0).cloned();
        RoomView {
            messages: msgs,
            participants,
            id: self.id.clone(),
            your_id: socket_id.to_string(),
            their_id,
            other_participant_ids: other_ids,
        }
    }
}

#[derive(Serialize)]
struct RoomView {
    messages: HashMap<String, Vec<String>>,
    participants: usize,
    id: String,
    #[serde(rename = "yourId")]
    your_id: String,
    #[serde(rename = "theirId")]
    their_id: Option<String>,
    #[serde(rename = "otherParticipantIds")]
    other_participant_ids: Vec<String>,
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
    let mut current_room: Option<Arc<Room>> = None;
    let mut socket_id: Option<String> = None;

    while let Some(Ok(msg)) = socket.recv().await {
        if let Message::Text(text) = msg {
            if let Ok(val) = serde_json::from_str::<ClientMsg>(&text) {
                match val {
                    ClientMsg::NewRoom { socketId } => {
                        let sid = socketId.unwrap_or_else(|| random_hex(20));
                        let rid = random_hex(6);
                        let room = Arc::new(Room::new(rid.clone()));
                        room.join(sid.clone()).await;
                        {
                            let mut map = rooms.inner.lock().await;
                            map.insert(rid.clone(), room.clone());
                        }
                        current_room = Some(room);
                        socket_id = Some(sid.clone());
                        let view = current_room.as_ref().unwrap().render(&sid).await;
                        let resp = json!({ "type": "roomCreated", "room": view });
                        let _ = socket.send(Message::Text(resp.to_string())).await;
                    }
                    ClientMsg::FetchRoom { id, socketId } => {
                        let sid = socketId.unwrap_or_else(|| random_hex(20));
                        let room = {
                            let mut map = rooms.inner.lock().await;
                            map.entry(id.clone()).or_insert_with(|| Arc::new(Room::new(id.clone()))).clone()
                        };
                        room.join(sid.clone()).await;
                        current_room = Some(room);
                        socket_id = Some(sid.clone());
                        let view = current_room.as_ref().unwrap().render(&sid).await;
                        let resp = json!({ "type": "gotRoom", "room": view });
                        let _ = socket.send(Message::Text(resp.to_string())).await;
                    }
                    ClientMsg::KeyPress { .. } => {
                        // keyPress handling not implemented in this prototype
                    }
                }
            }
        }
    }
}
