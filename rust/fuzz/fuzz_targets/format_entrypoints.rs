#![no_main]

use cad_core::CancellationToken;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let registry = cad_formats::default_registry();
    if let Some(adapter) = registry.detect(data, None) {
        let _ = adapter.open(
            data,
            "fuzz-input",
            None,
            &CancellationToken::default(),
            None,
        );
    }
});
