// Token Lifecycle Integration Tests
//
// Tests for validating the complete token lifecycle with Ledger-backed validation:
// - Certificate creation → JWT issuance → validation → revocation → rejection
// - Key rotation with grace period
// - Token expiration enforcement
//
// These tests validate the PRD Task 8 acceptance criteria for Ledger-based
// token validation.

use reqwest::StatusCode;
use serde::Deserialize;

use super::*;

/// Response from certificate rotation endpoint
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct RotateCertificateResponse {
    pub certificate: CertificateInfo,
    pub valid_from: String,
    pub rotated_from: CertificateInfo,
    pub private_key: String,
}

/// Response from certificate revocation endpoint
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct RevokeCertificateResponse {
    pub message: String,
}

// =============================================================================
// Full Token Lifecycle Test
// =============================================================================

/// Test: Full token lifecycle (create → issue → validate → revoke → reject)
///
/// This test validates the complete flow from certificate creation through
/// revocation, ensuring that:
/// 1. Certificate creation registers public key in Ledger
/// 2. JWT tokens can be validated using the Ledger-stored key
/// 3. Certificate revocation updates Ledger state
/// 4. Engine rejects tokens after key is revoked
#[tokio::test]
async fn test_full_token_lifecycle() {
    // Create test fixture (includes certificate registration in Ledger)
    let fixture = TestFixture::create().await.expect("Failed to create test fixture");

    // 1. Generate valid JWT
    let jwt = fixture.generate_jwt(None, &["inferadb.check"]).expect("Failed to generate JWT");

    // 2. Validate token via Engine - should succeed
    let response = fixture
        .call_server_evaluate(&jwt, "document:1", "viewer", "user:alice")
        .await
        .expect("Failed to call server");

    // Should succeed with 200 (evaluation result) or 404 (no relationships, but auth passed)
    assert!(
        response.status() == StatusCode::OK || response.status() == StatusCode::NOT_FOUND,
        "Expected 200 or 404 for valid token, got {}",
        response.status()
    );

    // 3. Revoke the certificate
    let revoke_url = fixture.ctx.control_url(&format!(
        "/organizations/{}/clients/{}/certificates/{}",
        fixture.org_id, fixture.client_id, fixture.cert_id
    ));

    let revoke_response = fixture
        .ctx
        .client
        .delete(&revoke_url)
        .header("Authorization", format!("Bearer {}", fixture.session_id))
        .send()
        .await
        .expect("Failed to revoke certificate");

    assert!(
        revoke_response.status().is_success(),
        "Certificate revocation failed with status {}",
        revoke_response.status()
    );

    // 4. Generate new JWT with the same (now revoked) key
    // The JWT is structurally valid but the key is revoked in Ledger
    let post_revoke_jwt = fixture
        .generate_jwt(None, &["inferadb.check"])
        .expect("Failed to generate post-revoke JWT");

    // 5. Attempt to validate - should fail with 401
    // Note: Cache TTL may cause brief delay, but Engine should check key state
    let rejected_response = fixture
        .call_server_evaluate(&post_revoke_jwt, "document:1", "viewer", "user:alice")
        .await
        .expect("Failed to call server after revocation");

    // Engine should reject the token because the key is revoked
    assert_eq!(
        rejected_response.status(),
        StatusCode::UNAUTHORIZED,
        "Expected 401 Unauthorized after key revocation, got {}. \
        Note: If this fails intermittently, the cache TTL may not have expired.",
        rejected_response.status()
    );

    fixture.cleanup().await.expect("Failed to cleanup");
}

// =============================================================================
// Key Rotation Grace Period Test
// =============================================================================

/// Test: Key rotation with grace period
///
/// This test validates that during key rotation:
/// 1. The old key remains valid immediately after rotation
/// 2. The new key's `valid_from` is in the future (grace period)
/// 3. Both keys can coexist allowing zero-downtime rotation
#[tokio::test]
async fn test_key_rotation_grace_period() {
    let fixture = TestFixture::create().await.expect("Failed to create test fixture");

    // 1. Verify original certificate works
    let original_jwt =
        fixture.generate_jwt(None, &["inferadb.check"]).expect("Failed to generate original JWT");

    let original_response = fixture
        .call_server_evaluate(&original_jwt, "document:1", "viewer", "user:alice")
        .await
        .expect("Failed to call server with original key");

    assert!(
        original_response.status() == StatusCode::OK
            || original_response.status() == StatusCode::NOT_FOUND,
        "Original key should be valid, got {}",
        original_response.status()
    );

    // 2. Rotate the certificate with a 5-minute (300 second) grace period
    let rotate_url = fixture.ctx.control_url(&format!(
        "/organizations/{}/clients/{}/certificates/{}/rotate",
        fixture.org_id, fixture.client_id, fixture.cert_id
    ));

    let rotate_response = fixture
        .ctx
        .client
        .post(&rotate_url)
        .header("Authorization", format!("Bearer {}", fixture.session_id))
        .json(&serde_json::json!({
            "name": format!("Rotated Certificate {}", Uuid::new_v4()),
            "grace_period_seconds": 300
        }))
        .send()
        .await
        .expect("Failed to rotate certificate");

    assert!(
        rotate_response.status().is_success(),
        "Certificate rotation failed with status {}",
        rotate_response.status()
    );

    let rotation_result: RotateCertificateResponse =
        rotate_response.json().await.expect("Failed to parse rotation response");

    // 3. Original key should still work immediately after rotation
    let post_rotate_original_jwt = fixture
        .generate_jwt(None, &["inferadb.check"])
        .expect("Failed to generate post-rotate JWT");

    let post_rotate_response = fixture
        .call_server_evaluate(&post_rotate_original_jwt, "document:1", "viewer", "user:alice")
        .await
        .expect("Failed to call server with original key after rotation");

    assert!(
        post_rotate_response.status() == StatusCode::OK
            || post_rotate_response.status() == StatusCode::NOT_FOUND,
        "Original key should still be valid after rotation, got {}",
        post_rotate_response.status()
    );

    // 4. New key should NOT be valid yet (within grace period)
    // Parse the new private key to create a JWT with the rotated key
    let new_private_key_bytes = base64::engine::general_purpose::STANDARD
        .decode(&rotation_result.private_key)
        .expect("Failed to decode new private key");

    let new_signing_key = SigningKey::from_bytes(
        &new_private_key_bytes.try_into().expect("Invalid private key length"),
    );

    // Generate JWT with the new (not-yet-valid) key
    let now = Utc::now();
    let claims = ClientClaims {
        iss: fixture.ctx.api_base_url.clone(),
        sub: format!("client:{}", fixture.client_id),
        aud: REQUIRED_AUDIENCE.to_string(),
        exp: (now + Duration::minutes(5)).timestamp(),
        iat: now.timestamp(),
        jti: Uuid::new_v4().to_string(),
        vault_id: fixture.vault_id.to_string(),
        org_id: fixture.org_id.to_string(),
        scope: "inferadb.check inferadb.read".to_string(),
        vault_role: "read".to_string(),
    };

    let mut header = Header::new(Algorithm::EdDSA);
    header.kid = Some(rotation_result.certificate.kid.clone());

    let new_secret_bytes = new_signing_key.to_bytes();
    let new_pem = ed25519_to_pem(&new_secret_bytes);
    let new_encoding_key =
        EncodingKey::from_ed_pem(&new_pem).expect("Failed to create encoding key for new key");

    let new_key_jwt =
        encode(&header, &claims, &new_encoding_key).expect("Failed to encode new JWT");

    // The new key should be rejected as "not yet valid"
    let new_key_response = fixture
        .call_server_evaluate(&new_key_jwt, "document:1", "viewer", "user:alice")
        .await
        .expect("Failed to call server with new key");

    assert_eq!(
        new_key_response.status(),
        StatusCode::UNAUTHORIZED,
        "New key should not be valid during grace period, got {}",
        new_key_response.status()
    );

    fixture.cleanup().await.expect("Failed to cleanup");
}

// =============================================================================
// Token Expiration Test
// =============================================================================

/// Test: Engine strictly honors token `exp` claim
///
/// This test is a confirmation that the existing `test_jwt_with_expired_token`
/// behavior matches PRD requirements. The Engine must reject tokens after their
/// expiration time, regardless of key validity.
///
/// Note: This test mirrors auth_jwt_tests::test_jwt_with_expired_token but is
/// included here for completeness of the token lifecycle test suite.
#[tokio::test]
async fn test_token_expiration_honored() {
    let fixture = TestFixture::create().await.expect("Failed to create test fixture");

    // Generate JWT that expired 10 minutes ago
    let now = Utc::now();
    let claims = ClientClaims {
        iss: fixture.ctx.api_base_url.clone(),
        sub: format!("client:{}", fixture.client_id),
        aud: REQUIRED_AUDIENCE.to_string(),
        exp: (now - Duration::minutes(10)).timestamp(), // Expired
        iat: (now - Duration::minutes(15)).timestamp(),
        jti: Uuid::new_v4().to_string(),
        vault_id: fixture.vault_id.to_string(),
        org_id: fixture.org_id.to_string(),
        scope: "inferadb.check inferadb.read".to_string(),
        vault_role: "read".to_string(),
    };

    let mut header = Header::new(Algorithm::EdDSA);
    header.kid = Some(fixture.cert_kid.clone());

    let secret_bytes = fixture.signing_key.to_bytes();
    let pem = ed25519_to_pem(&secret_bytes);
    let encoding_key = EncodingKey::from_ed_pem(&pem).expect("Failed to create encoding key");
    let expired_jwt =
        encode(&header, &claims, &encoding_key).expect("Failed to encode expired JWT");

    // Engine should reject expired tokens
    let response = fixture
        .call_server_evaluate(&expired_jwt, "document:1", "viewer", "user:alice")
        .await
        .expect("Failed to call server");

    assert_eq!(
        response.status(),
        StatusCode::UNAUTHORIZED,
        "Engine must reject expired tokens, got {}",
        response.status()
    );

    fixture.cleanup().await.expect("Failed to cleanup");
}

// =============================================================================
// Certificate Revocation Idempotency Test
// =============================================================================

/// Test: Revoking an already-revoked certificate returns appropriate error
///
/// This validates the revocation endpoint's idempotency and error handling.
#[tokio::test]
async fn test_certificate_revocation_idempotent() {
    let fixture = TestFixture::create().await.expect("Failed to create test fixture");

    let revoke_url = fixture.ctx.control_url(&format!(
        "/organizations/{}/clients/{}/certificates/{}",
        fixture.org_id, fixture.client_id, fixture.cert_id
    ));

    // First revocation should succeed
    let first_revoke = fixture
        .ctx
        .client
        .delete(&revoke_url)
        .header("Authorization", format!("Bearer {}", fixture.session_id))
        .send()
        .await
        .expect("Failed to send first revocation request");

    assert!(
        first_revoke.status().is_success(),
        "First revocation should succeed, got {}",
        first_revoke.status()
    );

    // Second revocation should fail with validation error (already revoked)
    let second_revoke = fixture
        .ctx
        .client
        .delete(&revoke_url)
        .header("Authorization", format!("Bearer {}", fixture.session_id))
        .send()
        .await
        .expect("Failed to send second revocation request");

    assert_eq!(
        second_revoke.status(),
        StatusCode::BAD_REQUEST,
        "Second revocation should fail with 400 (already revoked), got {}",
        second_revoke.status()
    );

    fixture.cleanup().await.expect("Failed to cleanup");
}

// =============================================================================
// Rotation of Revoked Certificate Test
// =============================================================================

/// Test: Cannot rotate a revoked certificate
///
/// This validates that the rotation endpoint correctly rejects attempts to
/// rotate certificates that have been revoked.
#[tokio::test]
async fn test_cannot_rotate_revoked_certificate() {
    let fixture = TestFixture::create().await.expect("Failed to create test fixture");

    // First revoke the certificate
    let revoke_url = fixture.ctx.control_url(&format!(
        "/organizations/{}/clients/{}/certificates/{}",
        fixture.org_id, fixture.client_id, fixture.cert_id
    ));

    let revoke_response = fixture
        .ctx
        .client
        .delete(&revoke_url)
        .header("Authorization", format!("Bearer {}", fixture.session_id))
        .send()
        .await
        .expect("Failed to revoke certificate");

    assert!(revoke_response.status().is_success(), "Revocation should succeed");

    // Attempt to rotate the revoked certificate
    let rotate_url = fixture.ctx.control_url(&format!(
        "/organizations/{}/clients/{}/certificates/{}/rotate",
        fixture.org_id, fixture.client_id, fixture.cert_id
    ));

    let rotate_response = fixture
        .ctx
        .client
        .post(&rotate_url)
        .header("Authorization", format!("Bearer {}", fixture.session_id))
        .json(&serde_json::json!({
            "name": format!("Should Fail {}", Uuid::new_v4()),
            "grace_period_seconds": 300
        }))
        .send()
        .await
        .expect("Failed to send rotation request");

    assert_eq!(
        rotate_response.status(),
        StatusCode::BAD_REQUEST,
        "Cannot rotate a revoked certificate, got {}",
        rotate_response.status()
    );

    fixture.cleanup().await.expect("Failed to cleanup");
}
