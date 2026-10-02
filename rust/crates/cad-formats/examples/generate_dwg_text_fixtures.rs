//! Self-authored fixtures; never copy a user's CAD files into the test bundle.
use acadrust::{
    entities::{
        attribute_definition::{HorizontalAlignment, VerticalAlignment},
        AttributeDefinition, AttributeEntity, Insert, MText, Text,
    },
    tables::BlockRecord,
    CadDocument, DwgWriter, EntityType, Line, Vector3,
};
use std::{env, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = PathBuf::from(env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&directory)?;
    let mut drawing = CadDocument::new();
    let mut child = BlockRecord::new("GLYPHS");
    child.handle = drawing.allocate_handle();
    child.base_point = Vector3::new(5.0, 7.0, 0.0);
    let child_handle = child.handle;
    drawing.block_records.add(child)?;
    let mut text = Text::with_value("中文 العربية বাংলা", Vector3::new(10.0, 20.0, 0.0));
    text.common.owner_handle = child_handle;
    text.height = 12.0;
    text.rotation = 0.3;
    drawing.add_entity(EntityType::Text(text))?;
    let mut paragraph = MText::new();
    paragraph.common.owner_handle = child_handle;
    paragraph.value = "日本語\\Pالعربية বাংলা".to_owned();
    paragraph.insertion_point = Vector3::new(10.0, 20.0, 0.0);
    paragraph.height = 12.0;
    paragraph.rectangle_width = 120.0;
    paragraph.rotation = 0.3;
    drawing.add_entity(EntityType::MText(paragraph))?;
    let mut parent = BlockRecord::new("ASSEMBLY");
    parent.handle = drawing.allocate_handle();
    parent.base_point = Vector3::new(-4.0, 3.0, 0.0);
    let parent_handle = parent.handle;
    drawing.block_records.add(parent)?;
    let mut inner = Insert::new("GLYPHS", Vector3::new(20.0, 30.0, 0.0))
        .with_scale(2.0, 3.0, 1.0)
        .with_rotation(0.6);
    inner.common.owner_handle = parent_handle;
    drawing.add_entity(EntityType::Insert(inner))?;
    drawing.add_entity(EntityType::Insert(
        Insert::new("ASSEMBLY", Vector3::new(100.0, 200.0, 0.0))
            .with_scale(-1.0, 2.0, 1.0)
            .with_rotation(-0.2),
    ))?;
    DwgWriter::write_to_file(directory.join("nested-text.dwg"), &drawing)?;

    let mut drawing = CadDocument::new();
    let mut block = BlockRecord::new("GRID");
    block.handle = drawing.allocate_handle();
    let handle = block.handle;
    drawing.block_records.add(block)?;
    let mut text = Text::with_value("中文 日本語 العربية", Vector3::new(4.0, 5.0, 0.0));
    text.height = 12.0;
    text.common.owner_handle = handle;
    drawing.add_entity(EntityType::Text(text))?;
    let mut line = Line::from_coords(4.0, 5.0, 0.0, 5.0, 5.0, 0.0);
    line.common.owner_handle = handle;
    drawing.add_entity(EntityType::Line(line))?;
    drawing.add_entity(EntityType::Insert(
        Insert::new("GRID", Vector3::new(10.0, 20.0, 0.0))
            .with_array(2, 2, 100.0, 200.0)
            .with_scale(2.0, 3.0, 1.0)
            .with_rotation(std::f64::consts::FRAC_PI_2),
    ))?;
    DwgWriter::write_to_file(directory.join("array-text.dwg"), &drawing)?;

    let mut drawing = CadDocument::new();
    let mut text = Text::with_value("中文 العربية", Vector3::new(10.0, 20.0, 30.0));
    text.height = 12.0;
    text.normal = Vector3::new(0.0, 0.6, 0.8);
    drawing.add_entity(EntityType::Text(text))?;
    let mut paragraph = MText::new();
    paragraph.value = "日本語\\Pالعربية".to_owned();
    paragraph.insertion_point = Vector3::new(100.0, 200.0, 30.0);
    paragraph.height = 12.0;
    paragraph.rectangle_width = 80.0;
    paragraph.normal = Vector3::new(0.0, 0.6, 0.8);
    paragraph.x_direction = Some(Vector3::new(1.0, 0.0, 0.0));
    drawing.add_entity(EntityType::MText(paragraph))?;
    DwgWriter::write_to_file(directory.join("tilted-text.dwg"), &drawing)?;

    let mut drawing = CadDocument::new();
    let mut block = BlockRecord::new("ATTR_GRID");
    block.handle = drawing.allocate_handle();
    let handle = block.handle;
    drawing.block_records.add(block)?;
    let mut line = Line::from_coords(0.0, 0.0, 0.0, 1.0, 0.0, 0.0);
    line.common.owner_handle = handle;
    drawing.add_entity(EntityType::Line(line))?;
    let mut insert = Insert::new("ATTR_GRID", Vector3::new(10.0, 20.0, 0.0))
        .with_array(2, 2, 100.0, 200.0)
        .with_scale(2.0, 3.0, 1.0)
        .with_rotation(std::f64::consts::FRAC_PI_2);
    insert.common.layer = "Labels".to_owned();
    insert.common.color = acadrust::Color::from_index(5);
    let mut layer = acadrust::tables::Layer::new("Labels");
    layer.handle = drawing.allocate_handle();
    drawing.layers.add(layer)?;
    let mut centered = AttributeEntity::simple("CENTER", "中文 العربية");
    centered.alignment_point = Vector3::new(30.0, 40.0, 0.0);
    centered.horizontal_alignment = HorizontalAlignment::Center;
    centered.vertical_alignment = VerticalAlignment::Top;
    centered.height = 12.0;
    centered.width_factor = 1.3;
    centered.oblique_angle = 0.25;
    centered.text_generation_flags = 2;
    centered.common.color = acadrust::Color::ByBlock;
    insert.attributes.push(centered);
    let mut fitted = AttributeEntity::simple("FIT", "日本語 বাংলা");
    fitted.set_position(Vector3::new(4.0, 5.0, 0.0));
    fitted.alignment_point = Vector3::new(34.0, 45.0, 0.0);
    fitted.horizontal_alignment = HorizontalAlignment::Fit;
    fitted.height = 12.0;
    fitted.text_generation_flags = 4;
    insert.attributes.push(fitted.clone());
    fitted.value = "ไทย aligned".to_owned();
    fitted.tag = "ALIGNED".to_owned();
    fitted.horizontal_alignment = HorizontalAlignment::Aligned;
    insert.attributes.push(fitted);
    let mut middle = AttributeEntity::simple("MIDDLE", "Middle עברית");
    middle.alignment_point = Vector3::new(-10.0, 30.0, 0.0);
    middle.horizontal_alignment = HorizontalAlignment::Middle;
    middle.height = 12.0;
    middle.common.color = acadrust::Color::ByBlock;
    insert.attributes.push(middle);
    let mut hidden = AttributeEntity::simple("HIDDEN", "不可见 invisible");
    hidden.flags.invisible = true;
    insert.attributes.push(hidden);
    let mut hidden = AttributeEntity::simple("COMMON_HIDDEN", "共同不可见");
    hidden.common.invisible = true;
    insert.attributes.push(hidden);
    drawing.add_entity(EntityType::Insert(insert))?;
    DwgWriter::write_to_file(directory.join("attribute-text.dwg"), &drawing)?;

    let mut drawing = CadDocument::new();
    let mut block = BlockRecord::new("CONSTANTS");
    block.handle = drawing.allocate_handle();
    block.base_point = Vector3::new(5.0, 7.0, 0.0);
    let owner = block.handle;
    drawing.block_records.add(block)?;
    let mut definition = AttributeDefinition::new(
        "FIXED".to_owned(),
        "Never display prompt".to_owned(),
        "中文 العربية".to_owned(),
    );
    definition.common.owner_handle = owner;
    definition.common.color = acadrust::Color::ByBlock;
    definition.flags.constant = true;
    definition.insertion_point = Vector3::new(-999.0, -999.0, 0.0);
    definition.alignment_point = Vector3::new(10.0, 20.0, 0.0);
    definition.horizontal_alignment = HorizontalAlignment::Center;
    definition.vertical_alignment = VerticalAlignment::Top;
    definition.height = 12.0;
    definition.width_factor = 1.25;
    definition.oblique_angle = 0.2;
    definition.text_generation_flags = 2;
    drawing.add_entity(EntityType::AttributeDefinition(definition.clone()))?;
    definition.common.handle = acadrust::Handle::NULL;
    definition.tag = "TILTED".to_owned();
    definition.default_value = "日本語 বাংলা".to_owned();
    definition.insertion_point = Vector3::new(10.0, 20.0, 30.0);
    definition.horizontal_alignment = HorizontalAlignment::Left;
    definition.vertical_alignment = VerticalAlignment::Baseline;
    definition.width_factor = 1.0;
    definition.oblique_angle = 0.0;
    definition.text_generation_flags = 0;
    definition.normal = Vector3::new(0.0, 0.6, 0.8);
    drawing.add_entity(EntityType::AttributeDefinition(definition.clone()))?;
    for (tag, invisible, common_hidden, constant) in [
        ("HIDDEN", true, false, true),
        ("COMMON_HIDDEN", false, true, true),
        ("VARIABLE", false, false, false),
    ] {
        let mut excluded = definition.clone();
        excluded.common.handle = acadrust::Handle::NULL;
        excluded.tag = tag.to_owned();
        excluded.default_value = tag.to_owned();
        excluded.flags.invisible = invisible;
        excluded.common.invisible = common_hidden;
        excluded.flags.constant = constant;
        drawing.add_entity(EntityType::AttributeDefinition(excluded))?;
    }
    let mut layer = acadrust::tables::Layer::new("Labels");
    layer.handle = drawing.allocate_handle();
    drawing.layers.add(layer)?;
    let mut insert = Insert::new("CONSTANTS", Vector3::new(100.0, 200.0, 0.0))
        .with_scale(2.0, 3.0, 1.0)
        .with_rotation(std::f64::consts::FRAC_PI_2)
        .with_array(2, 2, 100.0, 200.0);
    insert.common.layer = "Labels".to_owned();
    insert.common.color = acadrust::Color::from_index(5);
    drawing.add_entity(EntityType::Insert(insert))?;
    DwgWriter::write_to_file(directory.join("constant-text.dwg"), &drawing)?;
    println!(
        "Generated nested, array, tilted, attribute and constant DWG text fixtures in {}",
        directory.display()
    );
    Ok(())
}
