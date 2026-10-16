//! Windows DPAPI wrappers for the two secrets this app can hold: the Cursor session
//! token and remote-instance SSH passwords.
//!
//! Ciphertext is bound to the current Windows user account, so copying `usage.db` to
//! another machine or account yields undecryptable blobs rather than leaked credentials.

use anyhow::{anyhow, Result};

#[cfg(windows)]
pub fn protect(plaintext: &[u8]) -> Result<Vec<u8>> {
    use windows::Win32::Foundation::LocalFree;
    use windows::Win32::Foundation::HLOCAL;
    use windows::Win32::Security::Cryptography::{CryptProtectData, CRYPT_INTEGER_BLOB};

    unsafe {
        let input = CRYPT_INTEGER_BLOB {
            cbData: plaintext.len() as u32,
            pbData: plaintext.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        CryptProtectData(&input, None, None, None, None, 0, &mut output)
            .map_err(|e| anyhow!("CryptProtectData failed: {e}"))?;

        // DPAPI allocates the output buffer with LocalAlloc; copy it out, then free it.
        let slice = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        let _ = LocalFree(HLOCAL(output.pbData as *mut _));
        Ok(slice)
    }
}

#[cfg(windows)]
pub fn unprotect(ciphertext: &[u8]) -> Result<Vec<u8>> {
    use windows::Win32::Foundation::LocalFree;
    use windows::Win32::Foundation::HLOCAL;
    use windows::Win32::Security::Cryptography::{CryptUnprotectData, CRYPT_INTEGER_BLOB};

    unsafe {
        let input = CRYPT_INTEGER_BLOB {
            cbData: ciphertext.len() as u32,
            pbData: ciphertext.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        CryptUnprotectData(&input, None, None, None, None, 0, &mut output)
            .map_err(|e| anyhow!("CryptUnprotectData failed: {e}"))?;

        let slice = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        let _ = LocalFree(HLOCAL(output.pbData as *mut _));
        Ok(slice)
    }
}

// Non-Windows builds exist only so `cargo check` works on CI runners; the app targets
// Windows and these paths refuse to store secrets rather than storing them in the clear.
#[cfg(not(windows))]
pub fn protect(_plaintext: &[u8]) -> Result<Vec<u8>> {
    Err(anyhow!("credential storage requires Windows DPAPI"))
}

#[cfg(not(windows))]
pub fn unprotect(_ciphertext: &[u8]) -> Result<Vec<u8>> {
    Err(anyhow!("credential storage requires Windows DPAPI"))
}

pub fn protect_str(s: &str) -> Result<Vec<u8>> {
    protect(s.as_bytes())
}

pub fn unprotect_str(b: &[u8]) -> Result<String> {
    Ok(String::from_utf8(unprotect(b)?)?)
}
