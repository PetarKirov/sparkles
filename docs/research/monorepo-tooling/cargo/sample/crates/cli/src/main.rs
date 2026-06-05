use anyhow::Result;
use greeter::greet;

fn main() -> Result<()> {
    let name = std::env::args().nth(1).unwrap_or_else(|| "world".to_string());
    println!("{}", greet(&name)?);
    Ok(())
}
