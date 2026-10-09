/// Links the shared platform timing and thread-affinity helpers.
fn main() {
    println!("cargo:rerun-if-changed=../platform.c");
    println!("cargo:rerun-if-changed=../.bin/libplatform.a");
    println!(
        "cargo:rustc-link-search=native={}/../.bin",
        env!("CARGO_MANIFEST_DIR")
    );
    println!("cargo:rustc-link-lib=static=platform");
}
