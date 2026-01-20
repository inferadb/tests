#![deny(unsafe_code)]

// Integration tests for InferaDB engine-control authentication
//
// These tests validate end-to-end authentication flows between the engine
// and control, including JWT authentication, vault isolation, and
// cross-service integration.
//
// Tests run against a Tailscale-based dev environment deployed via:
//   inferadb dev start
//
// The test infrastructure automatically discovers the API URL from
// the local Tailscale CLI.

use std::{process::Command, sync::OnceLock};

use anyhow::{Context, Result};
use base64::Engine;
use chrono::{Duration, Utc};
use ed25519_dalek::{SigningKey, VerifyingKey};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use rand::RngCore;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// Re-export test modules
mod auth_jwt_tests;
mod cache_tests;
mod concurrency_tests;
mod control_integration_tests;
mod e2e_workflows_tests;
mod ledger_cache_invalidation_tests;
mod resilience_tests;
mod vault_isolation_tests;

/// Generate a random Ed25519 signing key
pub fn generate_signing_key() -> SigningKey {
    let mut rng = rand::rng();
    let mut bytes = [0u8; 32];
    rng.fill_bytes(&mut bytes);
    SigningKey::from_bytes(&bytes)
}

/// Convert raw Ed25519 private key bytes (32 bytes) to PKCS#8 PEM format
/// This matches what Control does for JWT signing
fn ed25519_to_pem(private_key: &[u8; 32]) -> Vec<u8> {
    // PKCS#8 v1 structure for Ed25519:
    // SEQUENCE {
    //   INTEGER 0 (version)
    //   SEQUENCE {
    //     OBJECT IDENTIFIER 1.3.101.112 (Ed25519)
    //   }
    //   OCTET STRING {
    //     OCTET STRING <32 bytes private key>
    //   }
    // }

    // Ed25519 OID: 1.3.101.112
    let mut pkcs8_der = vec![
        0x30, 0x2e, // SEQUENCE (46 bytes)
        0x02, 0x01, 0x00, // INTEGER 0 (version)
        0x30, 0x05, // SEQUENCE (algorithm)
        0x06, 0x03, 0x2b, 0x65, 0x70, // OID 1.3.101.112
        0x04, 0x22, // OCTET STRING (34 bytes)
        0x04, 0x20, // OCTET STRING (32 bytes)
    ];
    pkcs8_der.extend_from_slice(private_key);

    // Convert to PEM
    let pem = format!(
        "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
        base64::engine::general_purpose::STANDARD.encode(&pkcs8_der)
    );

    pem.into_bytes()
}

/// Required JWT audience for InferaDB Server API
/// This MUST match the server's REQUIRED_AUDIENCE constant
pub const REQUIRED_AUDIENCE: &str = "https://api.inferadb.com";

/// Cached API base URL discovered from Tailscale
static API_BASE_URL: OnceLock<String> = OnceLock::new();

/// Discover the tailnet domain from the local Tailscale CLI
fn discover_tailnet() -> Result<String> {
    let output = Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .context("Failed to run 'tailscale status --json'. Is Tailscale installed and running?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("Tailscale status failed: {}", stderr);
    }

    let status: serde_json::Value =
        serde_json::from_slice(&output.stdout).context("Failed to parse Tailscale status JSON")?;

    // Extract DNS name from Self.DNSName (e.g., "hostname.tail27bf77.ts.net.")
    let dns_name = status
        .get("Self")
        .and_then(|s| s.get("DNSName"))
        .and_then(|d| d.as_str())
        .context("Could not find DNSName in Tailscale status")?;

    // Extract tailnet domain (everything after first dot, removing trailing dot)
    // e.g., "hostname.tail27bf77.ts.net." -> "tail27bf77.ts.net"
    let tailnet = dns_name.trim_end_matches('.').split('.').skip(1).collect::<Vec<_>>().join(".");

    if tailnet.is_empty() {
        anyhow::bail!("Could not extract tailnet from DNSName: {}", dns_name);
    }

    Ok(tailnet)
}

/// Get the API base URL (discovers from Tailscale or uses environment override)
pub fn api_base_url() -> String {
    API_BASE_URL
        .get_or_init(|| {
            // Allow environment override for CI/testing
            if let Ok(url) = std::env::var("INFERADB_API_URL") {
                return url;
            }

            // Discover from Tailscale
            match discover_tailnet() {
                Ok(tailnet) => format!("https://inferadb-api.{}", tailnet),
                Err(e) => {
                    eprintln!("Warning: Could not discover Tailscale tailnet: {}", e);
                    eprintln!("Falling back to localhost. Set INFERADB_API_URL to override.");
                    "http://localhost:9090".to_string()
                },
            }
        })
        .clone()
}

/// Validate that the dev environment is running and accessible
pub async fn validate_environment() -> Result<()> {
    let base_url = api_base_url();
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .danger_accept_invalid_certs(true) // For dev self-signed certs
        .build()?;

    // Check health endpoint (routed to Control via ingress at /healthz)
    let health_url = format!("{}/healthz", base_url);
    let response = client.get(&health_url).send().await.context(format!(
        "Failed to connect to API at {}. Is the dev environment running? Run: inferadb dev start",
        health_url
    ))?;

    if !response.status().is_success() {
        anyhow::bail!(
            "Health check failed with status {}. Is the dev environment healthy?",
            response.status()
        );
    }

    println!("Environment validated: {}", base_url);
    Ok(())
}

/// Test context containing all necessary state for integration tests
#[derive(Clone)]
pub struct TestContext {
    pub client: Client,
    pub api_base_url: String,
}

impl Default for TestContext {
    fn default() -> Self {
        Self {
            client: Client::builder()
                .cookie_store(true)
                .timeout(std::time::Duration::from_secs(30))
                .danger_accept_invalid_certs(true) // For dev self-signed certs
                .build()
                .expect("Failed to create HTTP client"),
            api_base_url: api_base_url(),
        }
    }
}

impl TestContext {
    pub fn new() -> Self {
        Self::default()
    }

    /// Get Control API URL
    pub fn control_url(&self, path: &str) -> String {
        format!("{}/control/v1{}", self.api_base_url, path)
    }

    /// Get Engine (Access) API URL
    pub fn engine_url(&self, path: &str) -> String {
        format!("{}/access/v1{}", self.api_base_url, path)
    }
}

/// User registration request
#[derive(Debug, Serialize)]
pub struct RegisterRequest {
    pub name: String,
    pub email: String,
    pub password: String,
    pub accept_tos: bool,
}

/// User registration response
#[derive(Debug, Deserialize)]
pub struct RegisterResponse {
    pub user_id: i64,
    pub name: String,
    pub email: String,
    pub session_id: i64,
}

/// Login request
#[derive(Debug, Serialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

/// Login response with session
#[derive(Debug, Deserialize)]
pub struct LoginResponse {
    pub user_id: i64,
    pub name: String,
    pub session_id: i64,
}

/// Organization creation request
#[derive(Debug, Serialize)]
pub struct CreateOrganizationRequest {
    pub name: String,
}

/// Organization response
#[derive(Debug, Deserialize)]
pub struct OrganizationResponse {
    pub id: i64,
    pub name: String,
    pub tier: String,
    pub created_at: String,
    pub role: String,
}

/// List organizations response (paginated)
#[derive(Debug, Deserialize)]
pub struct ListOrganizationsResponse {
    pub organizations: Vec<OrganizationResponse>,
    pub pagination: Option<serde_json::Value>,
}

/// Vault creation request
#[derive(Debug, Serialize)]
pub struct CreateVaultRequest {
    pub name: String,
    pub organization_id: i64,
}

/// Vault info (inner structure)
#[derive(Debug, Deserialize)]
pub struct VaultInfo {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub organization_id: i64,
    pub sync_status: String,
    pub created_at: String,
}

/// Vault creation response (wraps vault info)
#[derive(Debug, Deserialize)]
pub struct CreateVaultResponse {
    pub vault: VaultInfo,
}

/// Vault response (for GET operations)
#[derive(Debug, Deserialize)]
pub struct VaultResponse {
    pub id: i64,
    pub name: String,
    pub organization_id: i64,
    pub sync_status: String,
    pub sync_error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

/// Client creation request
#[derive(Debug, Serialize)]
pub struct CreateClientRequest {
    pub name: String,
}

/// Client info (inner structure)
#[derive(Debug, Deserialize)]
pub struct ClientInfo {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub is_active: bool,
    pub organization_id: i64,
    pub created_at: String,
}

/// Client creation response (wraps client info)
#[derive(Debug, Deserialize)]
pub struct CreateClientResponse {
    pub client: ClientInfo,
}

/// Client response (for GET operations)
#[derive(Debug, Deserialize)]
pub struct ClientResponse {
    pub id: i64,
    pub name: String,
    pub is_active: bool,
    pub organization_id: i64,
    pub created_at: String,
}

/// Certificate creation request
#[derive(Debug, Serialize)]
pub struct CreateCertificateRequest {
    pub name: String,
}

/// Certificate response
#[derive(Debug, Deserialize)]
pub struct CertificateResponse {
    pub certificate: CertificateInfo,
    pub private_key: String,
}

#[derive(Debug, Deserialize)]
pub struct CertificateInfo {
    pub id: i64,
    pub kid: String,
    pub name: String,
    pub public_key: String,
    pub is_active: bool,
    pub created_at: String,
}

/// JWT claims for client authentication
/// Matches the Control specification (see control/docs/Authentication.md)
#[derive(Debug, Serialize, Deserialize)]
pub struct ClientClaims {
    pub iss: String,
    pub sub: String,
    pub aud: String,
    pub exp: i64,
    pub iat: i64,
    pub jti: String,
    pub vault_id: String,
    pub org_id: String,
    pub scope: String,
    pub vault_role: String,
}

/// Test fixture for creating a complete test environment
pub struct TestFixture {
    pub ctx: TestContext,
    pub user_id: i64,
    pub session_id: i64,
    pub org_id: i64,
    pub vault_id: i64,
    pub client_id: i64,
    pub cert_id: i64,
    pub cert_kid: String,
    pub signing_key: SigningKey,
    pub verifying_key: VerifyingKey,
}

impl TestFixture {
    /// Create a complete test fixture with user, org, vault, and client
    pub async fn create() -> Result<Self> {
        let ctx = TestContext::new();

        // Register user
        let email = format!("test-{}@example.com", Uuid::new_v4());
        let register_req = RegisterRequest {
            name: "Test User".to_string(),
            email: email.clone(),
            password: "SecurePassword123!".to_string(),
            accept_tos: true,
        };

        let response = ctx
            .client
            .post(ctx.control_url("/auth/register"))
            .json(&register_req)
            .send()
            .await
            .context("Failed to register user")?;

        let status = response.status();
        if !status.is_success() {
            let error_body =
                response.text().await.unwrap_or_else(|_| "Unable to read error body".to_string());
            anyhow::bail!("Registration failed with status {}: {}", status, error_body);
        }

        let register_resp: RegisterResponse =
            response.json().await.context("Failed to parse registration response")?;

        let user_id = register_resp.user_id;

        // Login to get session
        let login_req = LoginRequest { email, password: "SecurePassword123!".to_string() };

        let login_response = ctx
            .client
            .post(ctx.control_url("/auth/login/password"))
            .json(&login_req)
            .send()
            .await
            .context("Failed to login")?;

        let login_status = login_response.status();
        if !login_status.is_success() {
            let error_body = login_response
                .text()
                .await
                .unwrap_or_else(|_| "Unable to read error body".to_string());
            anyhow::bail!("Login failed with status {}: {}", login_status, error_body);
        }

        let login_resp: LoginResponse =
            login_response.json().await.context("Failed to parse login response")?;

        let session_id = login_resp.session_id;

        // Get default organization (created during registration)
        let orgs_response: ListOrganizationsResponse = ctx
            .client
            .get(ctx.control_url("/organizations"))
            .header("Authorization", format!("Bearer {}", session_id))
            .send()
            .await
            .context("Failed to list organizations")?
            .error_for_status()
            .context("List organizations failed")?
            .json()
            .await
            .context("Failed to parse organizations response")?;

        let org_id =
            orgs_response.organizations.first().context("No default organization found")?.id;

        // Create vault
        let vault_req = CreateVaultRequest {
            name: format!("Test Vault {}", Uuid::new_v4()),
            organization_id: org_id,
        };

        let create_vault_resp: CreateVaultResponse = ctx
            .client
            .post(ctx.control_url(&format!("/organizations/{}/vaults", org_id)))
            .header("Authorization", format!("Bearer {}", session_id))
            .json(&vault_req)
            .send()
            .await
            .context("Failed to create vault")?
            .error_for_status()
            .context("Vault creation failed")?
            .json()
            .await
            .context("Failed to parse vault response")?;

        let vault_id = create_vault_resp.vault.id;

        // Create client
        let client_req = CreateClientRequest { name: format!("Test Client {}", Uuid::new_v4()) };

        let create_client_resp: CreateClientResponse = ctx
            .client
            .post(ctx.control_url(&format!("/organizations/{}/clients", org_id)))
            .header("Authorization", format!("Bearer {}", session_id))
            .json(&client_req)
            .send()
            .await
            .context("Failed to create client")?
            .error_for_status()
            .context("Client creation failed")?
            .json()
            .await
            .context("Failed to parse client response")?;

        let client_id = create_client_resp.client.id;

        // Create certificate (server generates the keypair)
        let cert_req =
            CreateCertificateRequest { name: format!("Test Certificate {}", Uuid::new_v4()) };

        let cert_resp: CertificateResponse = ctx
            .client
            .post(ctx.control_url(&format!(
                "/organizations/{}/clients/{}/certificates",
                org_id, client_id
            )))
            .header("Authorization", format!("Bearer {}", session_id))
            .json(&cert_req)
            .send()
            .await
            .context("Failed to create certificate")?
            .error_for_status()
            .context("Certificate creation failed")?
            .json()
            .await
            .context("Failed to parse certificate response")?;

        let cert_id = cert_resp.certificate.id;
        let cert_kid = cert_resp.certificate.kid;

        // Parse the server-generated private key (base64 encoded)
        let private_key_bytes = base64::engine::general_purpose::STANDARD
            .decode(&cert_resp.private_key)
            .context("Failed to decode private key")?;
        let signing_key = SigningKey::from_bytes(
            &private_key_bytes
                .try_into()
                .map_err(|_| anyhow::anyhow!("Invalid private key length"))?,
        );
        let verifying_key = signing_key.verifying_key();

        Ok(Self {
            ctx,
            user_id,
            session_id,
            org_id,
            vault_id,
            client_id,
            cert_id,
            cert_kid,
            signing_key,
            verifying_key,
        })
    }

    /// Generate a JWT token for the client with specified vault and scopes
    pub fn generate_jwt(&self, vault_id: Option<i64>, scopes: &[&str]) -> Result<String> {
        let now = Utc::now();

        // Determine vault_role based on scopes (following control convention)
        let vault_role = if scopes.contains(&"inferadb.admin") {
            "admin"
        } else if scopes.contains(&"inferadb.vault.manage") {
            "manage"
        } else if scopes.contains(&"inferadb.write") {
            "write"
        } else {
            "read"
        };

        // Use scope format: space-separated inferadb.* scopes
        let scope_str = if scopes.is_empty() {
            // Default to read scope
            "inferadb.check inferadb.read inferadb.expand inferadb.list inferadb.list-relationships inferadb.list-subjects inferadb.list-resources".to_string()
        } else {
            scopes.join(" ")
        };

        let claims = ClientClaims {
            iss: self.ctx.api_base_url.clone(),
            sub: format!("client:{}", self.client_id),
            aud: REQUIRED_AUDIENCE.to_string(),
            exp: (now + Duration::minutes(5)).timestamp(),
            iat: now.timestamp(),
            jti: Uuid::new_v4().to_string(),
            vault_id: vault_id.unwrap_or(self.vault_id).to_string(),
            org_id: self.org_id.to_string(),
            scope: scope_str,
            vault_role: vault_role.to_string(),
        };

        let mut header = Header::new(Algorithm::EdDSA);
        header.kid = Some(self.cert_kid.clone());

        // Convert Ed25519 private key to PEM format for jsonwebtoken
        let secret_bytes = self.signing_key.to_bytes();
        let pem = ed25519_to_pem(&secret_bytes);
        let encoding_key =
            EncodingKey::from_ed_pem(&pem).context("Failed to create encoding key")?;

        encode(&header, &claims, &encoding_key).context("Failed to encode JWT")
    }

    /// Generate a JWT with a different signing key (for testing invalid signatures)
    pub fn generate_invalid_jwt(&self) -> Result<String> {
        let wrong_key = generate_signing_key();
        let now = Utc::now();

        let claims = ClientClaims {
            iss: self.ctx.api_base_url.clone(),
            sub: format!("client:{}", self.client_id),
            aud: REQUIRED_AUDIENCE.to_string(),
            exp: (now + Duration::minutes(5)).timestamp(),
            iat: now.timestamp(),
            jti: Uuid::new_v4().to_string(),
            vault_id: self.vault_id.to_string(),
            org_id: self.org_id.to_string(),
            scope: "inferadb.check inferadb.read inferadb.write inferadb.expand inferadb.list inferadb.list-relationships inferadb.list-subjects inferadb.list-resources".to_string(),
            vault_role: "write".to_string(),
        };

        let mut header = Header::new(Algorithm::EdDSA);
        header.kid = Some(self.cert_kid.clone());

        let secret_bytes = wrong_key.to_bytes();
        let pem = ed25519_to_pem(&secret_bytes);
        let encoding_key = EncodingKey::from_ed_pem(&pem)
            .context("Failed to create encoding key for invalid JWT")?;

        encode(&header, &claims, &encoding_key).context("Failed to encode invalid JWT")
    }

    /// Call engine evaluate endpoint with JWT
    pub async fn call_server_evaluate(
        &self,
        jwt: &str,
        resource: &str,
        permission: &str,
        subject: &str,
    ) -> Result<reqwest::Response> {
        // Build evaluation request matching the server's expected format
        let evaluation = serde_json::json!({
            "subject": subject,
            "resource": resource,
            "permission": permission,
            "trace": false
        });

        let body = serde_json::json!({
            "evaluations": [evaluation]
        });

        self.ctx
            .client
            .post(self.ctx.engine_url("/evaluate"))
            .header("Authorization", format!("Bearer {}", jwt))
            .json(&body)
            .send()
            .await
            .context("Failed to call server evaluate endpoint")
    }

    /// Cleanup test resources
    pub async fn cleanup(&self) -> Result<()> {
        // Delete vault
        let _ =
            self.ctx
                .client
                .delete(self.ctx.control_url(&format!(
                    "/organizations/{}/vaults/{}",
                    self.org_id, self.vault_id
                )))
                .header("Authorization", format!("Bearer {}", self.session_id))
                .send()
                .await;

        // Delete client
        let _ =
            self.ctx
                .client
                .delete(self.ctx.control_url(&format!(
                    "/organizations/{}/clients/{}",
                    self.org_id, self.client_id
                )))
                .header("Authorization", format!("Bearer {}", self.session_id))
                .send()
                .await;

        // Delete organization
        let _ = self
            .ctx
            .client
            .delete(self.ctx.control_url(&format!("/organizations/{}", self.org_id)))
            .header("Authorization", format!("Bearer {}", self.session_id))
            .send()
            .await;

        // Delete user
        let _ = self
            .ctx
            .client
            .delete(self.ctx.control_url(&format!("/users/{}", self.user_id)))
            .header("Authorization", format!("Bearer {}", self.session_id))
            .send()
            .await;

        Ok(())
    }
}

impl Drop for TestFixture {
    fn drop(&mut self) {
        // Best-effort cleanup on drop
        let ctx = self.ctx.clone();
        let session_id = self.session_id;
        let vault_id = self.vault_id;
        let org_id = self.org_id;
        let client_id = self.client_id;
        let user_id = self.user_id;

        tokio::spawn(async move {
            let _ = ctx
                .client
                .delete(ctx.control_url(&format!("/organizations/{}/vaults/{}", org_id, vault_id)))
                .header("Authorization", format!("Bearer {}", session_id))
                .send()
                .await;

            let _ = ctx
                .client
                .delete(
                    ctx.control_url(&format!("/organizations/{}/clients/{}", org_id, client_id)),
                )
                .header("Authorization", format!("Bearer {}", session_id))
                .send()
                .await;

            let _ = ctx
                .client
                .delete(ctx.control_url(&format!("/organizations/{}", org_id)))
                .header("Authorization", format!("Bearer {}", session_id))
                .send()
                .await;

            let _ = ctx
                .client
                .delete(ctx.control_url(&format!("/users/{}", user_id)))
                .header("Authorization", format!("Bearer {}", session_id))
                .send()
                .await;
        });
    }
}

// Legacy compatibility functions (deprecated - use TestContext methods instead)
#[deprecated(note = "Use TestContext::control_url() instead")]
pub fn control_url() -> String {
    api_base_url()
}

#[deprecated(note = "Use TestContext::engine_url() instead")]
pub fn engine_url() -> String {
    api_base_url()
}

#[deprecated(note = "No longer needed with unified Tailscale endpoint")]
pub fn engine_grpc_url() -> String {
    api_base_url()
}

#[deprecated(note = "No longer needed with unified Tailscale endpoint")]
pub fn engine_mesh_url() -> String {
    api_base_url()
}
