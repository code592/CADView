//! Report source ATTRIB visibility metadata without exposing drawing text.
//! This complements scene regression counts; it is not a compatibility oracle.
use acadrust::{entities::EntityType, DwgReader};
use std::env;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = env::args().nth(1).ok_or("DWG path is required")?;
    let document = DwgReader::from_file(path)?.read()?;
    let mut total = 0;
    let mut attribute_invisible = 0;
    let mut entity_invisible = 0;
    let mut visible = 0;
    let mut multiline = 0;
    let model_record = document.block_records.get("*Model_Space");
    let mut model_total = 0;
    let mut model_hidden = 0;
    for entity in document.entities() {
        if let EntityType::Insert(insert) = entity {
            let owner = insert.common.owner_handle;
            let is_model = (!owner.is_null() && owner == document.header.model_space_block_handle)
                || model_record.is_some_and(|record| {
                    (!record.handle.is_null() && owner == record.handle)
                        || record.entity_handles.contains(&insert.common.handle)
                });
            for attribute in &insert.attributes {
                total += 1;
                attribute_invisible += usize::from(attribute.flags.invisible);
                entity_invisible += usize::from(attribute.common.invisible);
                visible += usize::from(!attribute.flags.invisible && !attribute.common.invisible);
                multiline += usize::from(attribute.is_multiline);
                if is_model {
                    model_total += 1;
                    model_hidden +=
                        usize::from(attribute.flags.invisible || attribute.common.invisible);
                }
            }
        }
    }
    println!(
        "source ATTRIB: total={total}, attribute_invisible={attribute_invisible}, entity_invisible={entity_invisible}, visible={visible}, multiline={multiline}"
    );
    println!(
        "direct model INSERT ATTRIB: total={model_total}, hidden={model_hidden}; nested block attributes are counted only in the source totals above"
    );
    Ok(())
}
