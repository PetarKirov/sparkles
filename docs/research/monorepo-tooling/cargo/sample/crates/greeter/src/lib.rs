use anyhow::{Result, ensure};

/// Builds a greeting for `name`, rejecting empty input.
pub fn greet(name: &str) -> Result<String> {
    ensure!(!name.trim().is_empty(), "name must not be empty");
    Ok(format!("Hello, {name}!"))
}

#[cfg(test)]
mod tests {
    use super::greet;

    #[test]
    fn greets_a_name() {
        assert_eq!(greet("Cargo").unwrap(), "Hello, Cargo!");
    }

    #[test]
    fn rejects_empty() {
        assert!(greet("   ").is_err());
    }
}
