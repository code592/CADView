pub(crate) fn normalize_cad_text(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '%' && chars.peek() == Some(&'%') {
            chars.next();
            match chars.next().map(|value| value.to_ascii_lowercase()) {
                Some('d') => output.push('°'),
                Some('p') => output.push('±'),
                Some('c') => output.push('⌀'),
                Some(other) => {
                    output.push('%');
                    output.push('%');
                    output.push(other);
                }
                None => output.push_str("%%"),
            }
            continue;
        }
        if character != '\\' {
            if !matches!(character, '{' | '}') {
                output.push(character);
            }
            continue;
        }
        let Some(command) = chars.next() else {
            output.push('\\');
            break;
        };
        match command {
            'P' | 'p' => output.push('\n'),
            '~' => output.push(' '),
            '\\' | '{' | '}' => output.push(command),
            'U' | 'u' if chars.peek() == Some(&'+') => {
                chars.next();
                let digits = chars.by_ref().take(4).collect::<String>();
                if let Ok(codepoint) = u32::from_str_radix(&digits, 16) {
                    if let Some(decoded) = char::from_u32(codepoint) {
                        output.push(decoded);
                    }
                }
            }
            _ => {
                for next in chars.by_ref() {
                    if next == ';' {
                        break;
                    }
                }
            }
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_mtext_controls_but_keeps_symbols_and_unicode() {
        assert_eq!(normalize_cad_text(r"{\FArial;A}\P%%d \U+4E2D"), "A\n° 中");
    }
}
