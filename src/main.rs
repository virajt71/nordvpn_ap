use crate::config::ConfigManager;
use crate::docker::DockerManager;
use axum::http::Method;
use std::env;
use std::net::SocketAddr;
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tower_http::services::{ServeDir, ServeFile};
use tracing::{info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

mod api;
mod config;
mod docker;
mod wifi;

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ap_manager=info,tower_http=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    info!("Starting AP Manager Backend...");

    // Determine Project Root
    let mut project_root = env::current_dir().expect("Failed to get current directory");
    if !project_root.join("access_point").exists() {
        if let Some(parent) = project_root.parent() {
            if parent.join("access_point").exists() {
                project_root = parent.to_path_buf();
            }
        }
    }
    info!("Project Root detected: {:?}", project_root);

    // Get HOST_PROJECT_DIR environment variable (with docker inspect auto-detection fallback)
    let mut host_project_dir_defaulted = false;
    let host_project_dir = match env::var("HOST_PROJECT_DIR") {
        Ok(dir) => {
            if dir.trim().is_empty() {
                auto_detect_host_dir(&mut host_project_dir_defaulted, &project_root)
            } else {
                info!("HOST_PROJECT_DIR set to: {}", dir);
                dir
            }
        }
        Err(_) => {
            auto_detect_host_dir(&mut host_project_dir_defaulted, &project_root)
        }
    };

    // Initialize Managers
    let config_manager = Arc::new(ConfigManager::new(&project_root));
    let docker_manager = Arc::new(DockerManager::new(&project_root, &host_project_dir));

    // Load credentials
    let _creds = config_manager.load_credentials();

    // Broadcast channel for live stack-status snapshots (WebSocket subscribers).
    let (stack_tx, _stack_rx) = tokio::sync::broadcast::channel(16);

    // Setup state
    let state = api::AppState {
        config_manager,
        docker_manager,
        host_project_dir_defaulted,
        stack_tx,
    };

    // CORS configuration
    let cors = CorsLayer::new()
        .allow_methods([Method::GET, Method::POST, Method::PATCH, Method::DELETE])
        .allow_headers(Any)
        .allow_origin(Any);

    // Static files configuration
    let static_dir = project_root.join("static");
    let fallback_file = static_dir.join("index.html");

    info!("Static directory: {:?}", static_dir);

    // Create routes
    let app = api::create_router(state)
        .layer(cors)
        .layer(tower_http::trace::TraceLayer::new_for_http())
        .nest_service("/static", ServeDir::new(&static_dir))
        .fallback_service(ServeFile::new(fallback_file));

    // Address and listener setup
    let port = env::var("API_PORT")
        .unwrap_or_else(|_| "8080".to_string())
        .parse::<u16>()
        .unwrap_or(8080);
    
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    info!("Listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind TcpListener");

    axum::serve(listener, app).await.expect("Axum server run failed");
}

fn auto_detect_host_dir(defaulted: &mut bool, project_root: &std::path::Path) -> String {
    // Try to query docker inspect of the ap-manager container to find its host mount directory
    let output = std::process::Command::new("docker")
        .args([
            "inspect",
            "--format",
            "{{ range .Mounts }}{{ if eq .Destination \"/app\" }}{{ .Source }}{{ end }}{{ end }}",
            "ap-manager",
        ])
        .output();
        
    if let Ok(out) = output {
        let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !path.is_empty() {
            info!("Auto-detected HOST_PROJECT_DIR from docker inspect: {}", path);
            return path;
        }
    }

    *defaulted = true;
    let pwd = project_root.to_string_lossy().to_string();
    warn!(
        "HOST_PROJECT_DIR not set and auto-detection failed. Defaulting to current project root: {}",
        pwd
    );
    pwd
}
