//! Dashboard endpoints for viewing squads and members
//!
//! Password-protected admin dashboard with env var support

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::Html,
};
use serde::Deserialize;
use std::sync::Arc;

use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct DashboardQuery {
    pub password: Option<String>,
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn login_page() -> String {
    r#"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Squadz Dashboard - Login</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #eee;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .login-card {
            background: #16213e;
            border-radius: 12px;
            padding: 2rem;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
            text-align: center;
            max-width: 400px;
            width: 90%;
        }
        h1 { color: #4ade80; margin-bottom: 1rem; }
        p { color: #888; margin-bottom: 1.5rem; }
        input {
            width: 100%;
            padding: 0.75rem;
            margin-bottom: 1rem;
            border: none;
            border-radius: 8px;
            background: #0f3460;
            color: #fff;
            font-size: 1rem;
        }
        button {
            width: 100%;
            padding: 0.75rem;
            border: none;
            border-radius: 8px;
            background: #4ade80;
            color: #000;
            font-weight: bold;
            cursor: pointer;
            font-size: 1rem;
        }
        button:hover { background: #22c55e; }
    </style>
</head>
<body>
    <div class="login-card">
        <h1>🎯 Squadz Dashboard</h1>
        <p>Enter password to view squads</p>
        <form method="GET">
            <input type="password" name="password" placeholder="Password" autofocus>
            <button type="submit">Login</button>
        </form>
    </div>
</body>
</html>"#.to_string()
}

/// GET / - Dashboard HTML page
pub async fn dashboard_page(
    State(state): State<Arc<AppState>>,
    Query(query): Query<DashboardQuery>,
) -> Result<Html<String>, (StatusCode, String)> {
    // Check password from env var or use generated one
    let expected_password = &state.dashboard_password;
    let authenticated = query.password.as_deref() == Some(expected_password.as_str());
    
    if !authenticated {
        return Ok(Html(login_page()));
    }

    // Get all squads
    let squad_manager = state.squad_manager.read().await;
    let squads = squad_manager.list_squads();
    
    // Calculate stats
    let total_members: usize = squads.iter().map(|s| s.members.len()).sum();
    
    // Build squad cards HTML
    let mut squad_html = String::new();
    
    for squad in &squads {
        let members_html: String = squad.members.iter().map(|m| {
            format!(
                r#"<tr>
                    <td>{}</td>
                    <td><code>{}</code></td>
                    <td>{}</td>
                </tr>"#,
                html_escape(&m.display_name),
                &m.member_id.to_string()[..8],
                if m.is_leader { "👑 Leader" } else { "Member" }
            )
        }).collect();

        squad_html.push_str(&format!(
            r#"
            <div class="squad-card">
                <h3>🎯 {}</h3>
                <p><strong>Join Code:</strong> <code class="join-code">{}</code></p>
                <p><strong>Squad ID:</strong> <code>{}</code></p>
                <p><strong>Members:</strong> {}</p>
                <table>
                    <thead>
                        <tr><th>Name</th><th>ID</th><th>Role</th></tr>
                    </thead>
                    <tbody>{}</tbody>
                </table>
            </div>
            "#,
            html_escape(&squad.name),
            squad.join_code,
            &squad.squad_id.to_string()[..8],
            squad.members.len(),
            members_html
        ));
    }

    if squads.is_empty() {
        squad_html = r#"<div class="empty">No squads created yet. Use the API or mobile app to create one!</div>"#.to_string();
    }

    let html = format!(
        r##"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Squadz Dashboard</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #eee;
            min-height: 100vh;
            padding: 2rem;
        }}
        .container {{ max-width: 1200px; margin: 0 auto; }}
        h1 {{ font-size: 2rem; margin-bottom: 0.5rem; color: #4ade80; }}
        .subtitle {{ color: #888; margin-bottom: 2rem; }}
        .stats {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 1rem;
            margin-bottom: 2rem;
        }}
        .stat-card {{
            background: #16213e;
            border-radius: 12px;
            padding: 1.5rem;
            text-align: center;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
        }}
        .stat-value {{ font-size: 2.5rem; font-weight: bold; color: #4ade80; }}
        .stat-label {{ color: #888; margin-top: 0.5rem; }}
        .squad-card {{
            background: #16213e;
            border-radius: 12px;
            padding: 1.5rem;
            margin-bottom: 1rem;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
        }}
        .squad-card h3 {{ color: #4ade80; margin-bottom: 1rem; }}
        .squad-card p {{ margin: 0.5rem 0; }}
        code {{ background: #0f3460; padding: 0.2rem 0.5rem; border-radius: 4px; font-family: monospace; }}
        .join-code {{ font-size: 1.2rem; color: #fbbf24; background: #1e3a5f; }}
        table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; }}
        th, td {{ padding: 0.75rem; text-align: left; border-bottom: 1px solid #2a3f5f; }}
        th {{ color: #888; font-weight: normal; }}
        .empty {{ text-align: center; padding: 3rem; color: #888; background: #16213e; border-radius: 12px; }}
        .btn {{ 
            background: #3b82f6; color: white; border: none; padding: 0.75rem 1.5rem; 
            border-radius: 8px; cursor: pointer; font-size: 1rem; text-decoration: none;
            display: inline-block; margin-right: 0.5rem; margin-bottom: 1rem;
        }}
        .btn:hover {{ background: #2563eb; }}
        .btn-green {{ background: #4ade80; color: #000; }}
        .btn-green:hover {{ background: #22c55e; }}
        .crypto-section {{
            background: #16213e;
            border-radius: 12px;
            padding: 1.5rem;
            margin-bottom: 2rem;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
        }}
        .crypto-section h3 {{ color: #fbbf24; margin-bottom: 1rem; }}
        #crypto-result {{ 
            background: #0f3460; 
            padding: 1rem; 
            border-radius: 8px; 
            margin-top: 1rem;
            font-family: monospace;
            white-space: pre-wrap;
            display: none;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>🎯 Squadz Dashboard</h1>
        <p class="subtitle">Real-time squad tracking admin panel</p>
        
        <div class="stats">
            <div class="stat-card">
                <div class="stat-value">{}</div>
                <div class="stat-label">Active Squads</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">{}</div>
                <div class="stat-label">Total Members</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">✅</div>
                <div class="stat-label">Server Status</div>
            </div>
        </div>

        <a href="?password={}" class="btn">🔄 Refresh</a>
        
        <div class="crypto-section">
            <h3>🔐 Omni-Core-Lite Crypto Test</h3>
            <p>Test AES-256-GCM encryption round-trip with the server</p>
            <button class="btn btn-green" onclick="testCrypto()">Run Crypto Test</button>
            <div id="crypto-result"></div>
        </div>

        <h2 style="margin-bottom: 1rem;">Squads</h2>
        {}
    </div>
    
    <script>
        async function testCrypto() {{
            const result = document.getElementById('crypto-result');
            result.style.display = 'block';
            result.textContent = 'Testing crypto...';
            
            try {{
                // Test health
                const health = await fetch('/api/v1/crypto/health').then(r => r.json());
                
                // Test encrypt
                const encrypted = await fetch('/api/v1/crypto/encrypt', {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }},
                    body: JSON.stringify({{ plaintext: 'Hello from dashboard at ' + new Date().toISOString() }})
                }}).then(r => r.json());
                
                // Test decrypt
                const decrypted = await fetch('/api/v1/crypto/decrypt', {{
                    method: 'POST',
                    headers: {{ 'Content-Type': 'application/json' }},
                    body: JSON.stringify({{ nonce: encrypted.nonce, ciphertext: encrypted.ciphertext }})
                }}).then(r => r.json());
                
                result.textContent = `✅ Crypto Test PASSED!

Health: ${{JSON.stringify(health, null, 2)}}

Encrypted: ${{JSON.stringify(encrypted, null, 2)}}

Decrypted: ${{JSON.stringify(decrypted, null, 2)}}`;
            }} catch (err) {{
                result.textContent = '❌ Crypto Test FAILED: ' + err.message;
            }}
        }}
    </script>
</body>
</html>"##,
        squads.len(),
        total_members,
        expected_password,
        squad_html
    );

    Ok(Html(html))
}
