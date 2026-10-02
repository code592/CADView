// CADView local patch. Distributed under this crate's MIT license.
use encoding_rs::*;

/// Resolve known DXF $DWGCODEPAGE names without guessing unsupported OEM pages.
pub fn encoding_from_code_page(name: &str) -> Option<&'static Encoding> {
    let name = name.trim().to_ascii_lowercase();
    match name.as_str() {
        "" | "ascii" | "ansi_1252" => Some(WINDOWS_1252),
        "ansi_1250" => Some(WINDOWS_1250),
        "ansi_1251" => Some(WINDOWS_1251),
        "ansi_1253" => Some(WINDOWS_1253),
        "ansi_1254" => Some(WINDOWS_1254),
        "ansi_1255" => Some(WINDOWS_1255),
        "ansi_1256" => Some(WINDOWS_1256),
        "ansi_1257" => Some(WINDOWS_1257),
        "ansi_1258" => Some(WINDOWS_1258),
        "ansi_874" => Some(WINDOWS_874),
        "ansi_932" => Some(SHIFT_JIS),
        "ansi_936" | "gb2312" => Some(GBK),
        "ansi_950" => Some(BIG5),
        "ansi_949" | "korean" => Some(EUC_KR),
        "dos866" => Some(IBM866),
        _ => Encoding::for_label(name.as_bytes()),
    }
}
