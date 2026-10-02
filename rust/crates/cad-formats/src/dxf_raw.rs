//! Raw code-pair pass for DXF entity types the pinned `dxf` crate discards.
//!
//! HATCH boundaries are read here (their outlines are what the DWG path
//! renders via acadrust's explode as well). Every other discarded type is only
//! counted, so the document can report it instead of silently omitting it.

use crate::curves::{tessellate_spline, SplineSource};
use crate::mleader::{
    CmColor, LeaderBranch, LeaderLine, LeaderPath, MLeaderBlock, MLeaderModel, MLeaderText,
};
use crate::ocs_curves::{ocs_axes_or_world, ocs_world_point, tessellate_bulged_polyline};
use cad_core::{CadError, CancellationToken, Point2};
use dxf::{CodePair, CodePairValue, Drawing};
use std::collections::{BTreeMap, HashMap};
use std::f64::consts::{PI, TAU};
use std::io::Cursor;

/// Entity type strings modeled by the pinned `dxf` 0.6.1 reader.
const MODELED: &[&str] = &[
    "3DFACE",
    "3DSOLID",
    "ACAD_PROXY_ENTITY",
    "ARC",
    "ARCALIGNEDTEXT",
    "ATTDEF",
    "ATTRIB",
    "BODY",
    "CIRCLE",
    "DIMENSION",
    "ELLIPSE",
    "HELIX",
    "IMAGE",
    "INSERT",
    "LEADER",
    "LIGHT",
    "LINE",
    "3DLINE",
    "LWPOLYLINE",
    "MLINE",
    "MTEXT",
    "OLEFRAME",
    "OLE2FRAME",
    "POINT",
    "POLYLINE",
    "RAY",
    "REGION",
    "RTEXT",
    "SECTION",
    "SEQEND",
    "SHAPE",
    "SOLID",
    "SPLINE",
    "TEXT",
    "TOLERANCE",
    "TRACE",
    "DGNUNDERLAY",
    "DWFUNDERLAY",
    "PDFUNDERLAY",
    "VERTEX",
    "WIPEOUT",
    "XLINE",
];

const MAX_HATCH_PATHS: usize = 10_000;
const MAX_HATCH_ITEMS: usize = 100_000;

#[derive(Debug, Clone, Default)]
pub(crate) struct RawColor {
    /// ACI 1..255, 0 = ByBlock, 256 = ByLayer (also the default).
    pub aci: Option<i16>,
    pub rgb: Option<u32>,
}

#[derive(Debug, Clone)]
pub(crate) struct RawHatch {
    pub layer: String,
    pub color: RawColor,
    pub visible: bool,
    pub solid: bool,
    /// World-XY outline pieces. A boundary loop is normally one closed piece;
    /// a loop whose edges do not connect is split rather than bridged.
    pub pieces: Vec<(Vec<Point2>, bool)>,
    pub loop_count: usize,
}

#[derive(Debug, Default)]
pub(crate) struct RawScan {
    /// HATCH entities keyed by owner: None for ENTITIES, otherwise the
    /// uppercase block name.
    pub hatches: HashMap<Option<String>, Vec<RawHatch>>,
    /// Entity type strings the `dxf` reader discards (excluding HATCH).
    pub discarded: BTreeMap<String, u64>,
    pub unreadable_hatches: u64,
    pub tables: HashMap<Option<String>, Vec<RawTable>>,
    pub mleaders: HashMap<Option<String>, Vec<RawMLeader>>,
    pub unreadable_mleaders: u64,
}

/// Common properties of an entity read from raw pairs.
#[derive(Debug, Clone)]
pub(crate) struct RawCommon {
    pub layer: String,
    pub color: RawColor,
    pub visible: bool,
}

/// ACAD_TABLE: an INSERT-derived entity whose anonymous `*T` block holds
/// the rendered grid and cell text.
#[derive(Debug, Clone)]
pub(crate) struct RawTable {
    pub common: RawCommon,
    pub block_name: String,
    /// Group 343, the owning BLOCK_RECORD handle.
    pub block_record: Option<u64>,
    pub insertion: [f64; 3],
    pub direction: [f64; 3],
    pub normal: [f64; 3],
}

#[derive(Debug, Clone)]
pub(crate) struct RawMLeader {
    pub common: RawCommon,
    pub model: MLeaderModel,
}

/// [spline_fit_data]: R2010+ spline edges carry fit points (group 97) before
/// the path's own boundary-handle count, which also uses group 97.
pub(crate) fn scan(
    bytes: &[u8],
    encoding: &'static encoding_rs::Encoding,
    spline_fit_data: bool,
    cancel: &CancellationToken,
) -> Result<RawScan, CadError> {
    let mut result = RawScan::default();
    let pairs = Drawing::raw_code_pairs(&mut Cursor::new(bytes), encoding)
        .map_err(|error| CadError::InvalidDocument(format!("DXF parse failed: {error}")))?;
    let mut section: Option<String> = None;
    let mut expect_section = false;
    let mut block: Option<String> = None;
    let mut expect_block = false;
    // (entity type, pairs) of a HATCH, ACAD_TABLE or MULTILEADER being read.
    let mut collected: Option<(&'static str, Vec<CodePair>)> = None;
    let mut owner: Option<String> = None;
    for (index, pair) in pairs.enumerate() {
        if index % 65_536 == 0 {
            cancel.check()?;
        }
        // A malformed tail was already reported by the typed reader, which
        // succeeded; keep everything gathered so far.
        let Ok(pair) = pair else { break };
        if pair.code == 0 {
            match collected.take() {
                Some(("HATCH", pairs)) => match parse_hatch(&pairs, spline_fit_data) {
                    Some(parsed) => result
                        .hatches
                        .entry(owner.clone())
                        .or_default()
                        .push(parsed),
                    None => result.unreadable_hatches += 1,
                },
                Some(("ACAD_TABLE", pairs)) => match parse_table(&pairs) {
                    Some(parsed) => result.tables.entry(owner.clone()).or_default().push(parsed),
                    None => *result.discarded.entry("ACAD_TABLE".to_owned()).or_default() += 1,
                },
                Some((_, pairs)) => match parse_mleader(&pairs) {
                    Some(parsed) => result
                        .mleaders
                        .entry(owner.clone())
                        .or_default()
                        .push(parsed),
                    None => result.unreadable_mleaders += 1,
                },
                None => {}
            }
            let CodePairValue::Str(value) = &pair.value else {
                continue;
            };
            match value.as_str() {
                "SECTION" => expect_section = true,
                "ENDSEC" => {
                    section = None;
                    block = None;
                }
                "BLOCK" => expect_block = true,
                "ENDBLK" => block = None,
                "EOF" => break,
                kind => {
                    let in_entities = section.as_deref() == Some("ENTITIES");
                    let in_block = section.as_deref() == Some("BLOCKS") && block.is_some();
                    if !(in_entities || in_block) {
                        continue;
                    }
                    let raw_kind = match kind {
                        "HATCH" => Some("HATCH"),
                        "ACAD_TABLE" => Some("ACAD_TABLE"),
                        "MULTILEADER" | "MLEADER" => Some("MULTILEADER"),
                        _ => None,
                    };
                    if let Some(raw_kind) = raw_kind {
                        owner = if in_entities { None } else { block.clone() };
                        collected = Some((raw_kind, Vec::new()));
                    } else if !MODELED.contains(&kind) {
                        *result.discarded.entry(kind.to_owned()).or_default() += 1;
                    }
                }
            }
            continue;
        }
        if expect_section && pair.code == 2 {
            section = string(&pair);
            expect_section = false;
        } else if expect_block && pair.code == 2 {
            block = string(&pair).map(|name| name.to_uppercase());
            expect_block = false;
        }
        if let Some((_, pairs)) = collected.as_mut() {
            pairs.push(pair);
        }
    }
    Ok(result)
}

fn string(pair: &CodePair) -> Option<String> {
    match &pair.value {
        CodePairValue::Str(value) => Some(value.clone()),
        _ => None,
    }
}

fn number(pair: &CodePair) -> Option<f64> {
    let value = match pair.value {
        CodePairValue::Double(value) => value,
        CodePairValue::Short(value) | CodePairValue::Boolean(value) => value as f64,
        CodePairValue::Integer(value) => value as f64,
        CodePairValue::Long(value) => value as f64,
        _ => return None,
    };
    value.is_finite().then_some(value)
}

/// Sequential reader over one entity's pairs. Required values may be
/// preceded by a few unexpected pairs (vendor extensions); optional values
/// are only consumed when they are next.
struct Reader<'a> {
    pairs: &'a [CodePair],
    position: usize,
}

impl Reader<'_> {
    fn take(&mut self, code: i32) -> Option<f64> {
        let window = self.pairs.get(self.position..)?.iter().take(4);
        let offset = window.take_while(|pair| pair.code != code).count();
        let pair = self.pairs.get(self.position + offset)?;
        if pair.code != code {
            return None;
        }
        self.position += offset + 1;
        number(pair)
    }

    fn take_if(&mut self, code: i32) -> Option<f64> {
        let pair = self.pairs.get(self.position)?;
        if pair.code != code {
            return None;
        }
        self.position += 1;
        number(pair)
    }

    fn count(&mut self, code: i32) -> Option<usize> {
        let value = self.take(code)?;
        (value >= 0.0 && value <= MAX_HATCH_ITEMS as f64).then_some(value as usize)
    }

    fn point(&mut self, x: i32, y: i32) -> Option<[f64; 2]> {
        Some([self.take(x)?, self.take(y)?])
    }
}

fn parse_hatch(pairs: &[CodePair], spline_fit_data: bool) -> Option<RawHatch> {
    let mut layer = "0".to_owned();
    let mut color = RawColor::default();
    let mut visible = true;
    let mut start = 0;
    for (index, pair) in pairs.iter().enumerate() {
        match pair.code {
            8 => layer = string(pair).unwrap_or(layer),
            60 => visible = number(pair) != Some(1.0),
            62 => color.aci = number(pair).map(|value| value as i16),
            420 => color.rgb = number(pair).map(|value| value as u32 & 0xffffff),
            100 if string(pair).as_deref() == Some("AcDbHatch") => {
                start = index + 1;
                break;
            }
            _ => {}
        }
    }
    let mut reader = Reader {
        pairs,
        position: start,
    };
    reader.take(10)?;
    reader.take(20)?;
    let elevation = reader.take_if(30).unwrap_or(0.0);
    let normal = [
        reader.take_if(210).unwrap_or(0.0),
        reader.take_if(220).unwrap_or(0.0),
        reader.take_if(230).unwrap_or(1.0),
    ];
    let axes = ocs_axes_or_world(normal);
    let project = |x: f64, y: f64| {
        let world = ocs_world_point(axes, [x, y, elevation]);
        Point2::new(world[0], world[1])
    };
    let solid = {
        let mut lookahead = Reader {
            pairs,
            position: reader.position,
        };
        lookahead.take(70) == Some(1.0)
    };
    let path_count = reader.count(91)?;
    if path_count > MAX_HATCH_PATHS {
        return None;
    }
    let mut pieces = Vec::new();
    for _ in 0..path_count {
        let flags = reader.take(92)? as i64;
        if flags & 2 != 0 {
            let has_bulge = reader.take(72)? != 0.0;
            let closed = reader.take(73)? != 0.0;
            let count = reader.count(93)?;
            let mut vertices = Vec::with_capacity(count.min(4096));
            for _ in 0..count {
                let [x, y] = reader.point(10, 20)?;
                let bulge = if has_bulge {
                    reader.take_if(42).unwrap_or(0.0)
                } else {
                    0.0
                };
                vertices.push((x, y, bulge));
            }
            let closing = vertices.len() > 1
                && vertices.first().map(|v| (v.0, v.1)) == vertices.last().map(|v| (v.0, v.1));
            let points = tessellate_bulged_polyline(&vertices, closed && !closing, project);
            pieces.push((points, true));
        } else {
            let count = reader.count(93)?;
            let mut loop_pieces: Vec<Vec<Point2>> = Vec::new();
            for _ in 0..count {
                let edge = edge_points(&mut reader, &project, spline_fit_data)?;
                append_edge(&mut loop_pieces, edge);
            }
            let single = loop_pieces.len() == 1;
            for piece in loop_pieces {
                let closed = single && piece.len() > 2 && near(piece[0], *piece.last().unwrap());
                pieces.push((piece, closed));
            }
        }
        // Source boundary object handles.
        if let Some(count) = reader.take_if(97) {
            for _ in 0..(count.max(0.0) as usize).min(MAX_HATCH_ITEMS) {
                if reader.take_if(330).is_none() {
                    break;
                }
            }
        }
    }
    Some(RawHatch {
        layer,
        color,
        visible,
        solid,
        loop_count: path_count,
        pieces,
    })
}

fn edge_points(
    reader: &mut Reader<'_>,
    project: &impl Fn(f64, f64) -> Point2,
    spline_fit_data: bool,
) -> Option<Vec<Point2>> {
    match reader.take(72)? as i64 {
        1 => {
            let start = reader.point(10, 20)?;
            let end = reader.point(11, 21)?;
            Some(vec![project(start[0], start[1]), project(end[0], end[1])])
        }
        2 => {
            let center = reader.point(10, 20)?;
            let radius = reader.take(40)?;
            let (start, sweep) = edge_angles(reader)?;
            let steps = (sweep.abs() / (PI / 36.0)).ceil().clamp(2.0, 72.0) as usize;
            Some(
                (0..=steps)
                    .map(|index| {
                        let angle = start + sweep * index as f64 / steps as f64;
                        project(
                            center[0] + radius * angle.cos(),
                            center[1] + radius * angle.sin(),
                        )
                    })
                    .collect(),
            )
        }
        3 => {
            let center = reader.point(10, 20)?;
            let major = reader.point(11, 21)?;
            let ratio = reader.take(40)?;
            let (start, sweep) = edge_angles(reader)?;
            // P(t) = C + M cos t + m sin t, with m the major axis turned +90°
            // and scaled by the ratio (hatch edges lie in the hatch OCS).
            let minor = [-major[1] * ratio, major[0] * ratio];
            let steps = (sweep.abs() / (PI / 36.0)).ceil().clamp(2.0, 72.0) as usize;
            Some(
                (0..=steps)
                    .map(|index| {
                        let (sin, cos) = (start + sweep * index as f64 / steps as f64).sin_cos();
                        project(
                            center[0] + major[0] * cos + minor[0] * sin,
                            center[1] + major[1] * cos + minor[1] * sin,
                        )
                    })
                    .collect(),
            )
        }
        4 => {
            let degree = reader.take(94)? as i32;
            let rational = reader.take(73)? != 0.0;
            reader.take(74)?;
            let knot_count = reader.count(95)?;
            let control_count = reader.count(96)?;
            let mut knots = Vec::with_capacity(knot_count.min(4096));
            for _ in 0..knot_count {
                knots.push(reader.take(40)?);
            }
            let mut controls = Vec::with_capacity(control_count.min(4096));
            let mut weights = Vec::new();
            for _ in 0..control_count {
                let [x, y] = reader.point(10, 20)?;
                controls.push([x, y, 0.0]);
                if rational {
                    weights.push(reader.take_if(42).unwrap_or(1.0));
                }
            }
            let mut fit = Vec::new();
            if let Some(count) = spline_fit_data.then(|| reader.take_if(97)).flatten() {
                for _ in 0..(count.max(0.0) as usize).min(MAX_HATCH_ITEMS) {
                    let [x, y] = reader.point(11, 21)?;
                    fit.push([x, y, 0.0]);
                }
                for code in [12, 22, 13, 23] {
                    reader.take_if(code);
                }
            }
            let points = tessellate_spline(&SplineSource {
                degree,
                knots: &knots,
                control_points: &controls,
                weights: &weights,
                fit_points: &fit,
                closed: false,
            });
            Some(points.into_iter().map(|p| project(p.x, p.y)).collect())
        }
        _ => None,
    }
}

/// Start angle and signed sweep (radians) of a hatch arc/ellipse edge. A
/// clockwise edge (73 = 0) stores mirrored angles; following libdxfrw and
/// LibreCAD, its geometric angles are 2π − stored and it is traced clockwise.
fn edge_angles(reader: &mut Reader<'_>) -> Option<(f64, f64)> {
    let start = reader.take(50)?.to_radians();
    let end = reader.take(51)?.to_radians();
    let counter_clockwise = reader.take(73).unwrap_or(1.0) != 0.0;
    let mut sweep = (end - start).rem_euclid(TAU);
    if sweep <= 1e-12 {
        sweep = TAU;
    }
    Some(if counter_clockwise {
        (start, sweep)
    } else {
        (TAU - start, -sweep)
    })
}

fn near(a: Point2, b: Point2) -> bool {
    let scale =
        a.x.abs()
            .max(a.y.abs())
            .max(b.x.abs())
            .max(b.y.abs())
            .max(1.0);
    (a.x - b.x).abs() <= scale * 1e-9 && (a.y - b.y).abs() <= scale * 1e-9
}

/// Appends an edge to the current piece, reversing it when it was stored in
/// the opposite direction. Edges that do not touch start a new piece, so a
/// gap in the source boundary is never bridged by an invented chord.
fn append_edge(pieces: &mut Vec<Vec<Point2>>, mut edge: Vec<Point2>) {
    if edge.len() < 2 {
        return;
    }
    if let Some(current) = pieces.last_mut() {
        let end = *current.last().unwrap();
        if !near(end, edge[0]) && near(end, *edge.last().unwrap()) {
            edge.reverse();
        }
        if near(end, edge[0]) {
            current.extend(edge.into_iter().skip(1));
            return;
        }
        if current.len() == 2 && near(current[0], edge[0]) {
            // The first edge itself was stored reversed.
            current.reverse();
            current.extend(edge.into_iter().skip(1));
            return;
        }
    }
    pieces.push(edge);
}

fn parse_common(pairs: &[CodePair]) -> RawCommon {
    let mut common = RawCommon {
        layer: "0".to_owned(),
        color: RawColor::default(),
        visible: true,
    };
    for pair in pairs {
        match pair.code {
            8 => common.layer = string(pair).unwrap_or(common.layer),
            60 => common.visible = number(pair) != Some(1.0),
            62 => common.color.aci = number(pair).map(|value| value as i16),
            420 => common.color.rgb = number(pair).map(|value| value as u32 & 0xffffff),
            100 if string(pair).as_deref() != Some("AcDbEntity") => break,
            _ => {}
        }
    }
    common
}

fn handle(pair: &CodePair) -> Option<u64> {
    let value = string(pair)?;
    u64::from_str_radix(value.trim(), 16)
        .ok()
        .filter(|value| *value != 0)
}

/// Reads a point whose X is at [index]; Y and Z follow as code+10, code+20.
fn point_at(pairs: &[CodePair], index: usize) -> [f64; 3] {
    let code = pairs[index].code;
    let mut point = [number(&pairs[index]).unwrap_or(0.0), 0.0, 0.0];
    for (offset, axis) in [(1, 1), (2, 2)] {
        if let Some(pair) = pairs.get(index + offset) {
            if pair.code == code + 10 * axis as i32 {
                point[axis] = number(pair).unwrap_or(0.0);
            }
        }
    }
    point
}

fn parse_table(pairs: &[CodePair]) -> Option<RawTable> {
    let common = parse_common(pairs);
    let mut block_name = None;
    let mut block_record = None;
    let mut insertion = [0.0; 3];
    let mut direction = [1.0, 0.0, 0.0];
    let mut normal = [0.0, 0.0, 1.0];
    for (index, pair) in pairs.iter().enumerate() {
        match pair.code {
            2 if block_name.is_none() => block_name = string(pair),
            343 if block_record.is_none() => block_record = handle(pair),
            10 => insertion = point_at(pairs, index),
            11 => direction = point_at(pairs, index),
            210 => normal = point_at(pairs, index),
            _ => {}
        }
    }
    Some(RawTable {
        common,
        block_name: block_name.unwrap_or_default(),
        block_record,
        insertion,
        direction,
        normal,
    })
}

#[derive(Clone, Copy, PartialEq)]
enum MLeaderLevel {
    Top,
    Context,
    Leader,
    Line,
}

/// Reads the MULTILEADER group codes (DXF reference "MLEADER"): the
/// `CONTEXT_DATA{` section carries the effective text/block content and the
/// `LEADER{`/`LEADER_LINE{` geometry; the trailing entity-level codes carry
/// path type, colors, dogleg and arrowhead settings.
fn parse_mleader(pairs: &[CodePair]) -> Option<RawMLeader> {
    let common = parse_common(pairs);
    let mut level = MLeaderLevel::Top;
    let mut seen_context = false;
    let mut branches: Vec<LeaderBranch> = Vec::new();
    let mut has_text = false;
    let mut has_block = false;
    let mut text = MLeaderText {
        value: String::new(),
        location: [0.0; 3],
        direction: [1.0, 0.0, 0.0],
        normal: [0.0, 0.0, 1.0],
        height: 0.0,
        width: 0.0,
        line_spacing_factor: 1.0,
        alignment: 1,
        style_handle: None,
        color: CmColor::ByBlock,
    };
    let mut block = MLeaderBlock {
        block_handle: 0,
        location: [0.0; 3],
        normal: [0.0, 0.0, 1.0],
        scale: [1.0; 3],
        rotation: 0.0,
        color: CmColor::ByBlock,
    };
    let mut context_arrow = 0.0;
    let mut scale = 1.0;
    let mut path = LeaderPath::Straight;
    let mut line_color = CmColor::ByBlock;
    let mut dogleg_enabled = true;
    let mut arrow_size = 0.0;
    let mut arrow_handle = None;
    let mut top_block_handle = None;
    for (index, pair) in pairs.iter().enumerate() {
        let marker = string(pair);
        match (level, pair.code, marker.as_deref()) {
            (MLeaderLevel::Top, 300, _) if !seen_context => {
                level = MLeaderLevel::Context;
                seen_context = true;
                continue;
            }
            (MLeaderLevel::Context, 301, _) => {
                level = MLeaderLevel::Top;
                continue;
            }
            (MLeaderLevel::Context, 302, Some(value)) if value.starts_with("LEADER") => {
                level = MLeaderLevel::Leader;
                branches.push(LeaderBranch {
                    lines: Vec::new(),
                    last_point: None,
                    dogleg: [1.0, 0.0, 0.0],
                    dogleg_length: 0.0,
                });
                continue;
            }
            (MLeaderLevel::Leader, 303, _) => {
                level = MLeaderLevel::Context;
                continue;
            }
            (MLeaderLevel::Leader, 304, Some(value)) if value.starts_with("LEADER_LINE") => {
                level = MLeaderLevel::Line;
                branches
                    .last_mut()?
                    .lines
                    .push(LeaderLine { points: Vec::new() });
                continue;
            }
            (MLeaderLevel::Line, 305, _) => {
                level = MLeaderLevel::Leader;
                continue;
            }
            _ => {}
        }
        match level {
            MLeaderLevel::Line => {
                if pair.code == 10 {
                    let point = point_at(pairs, index);
                    branches.last_mut()?.lines.last_mut()?.points.push(point);
                }
            }
            MLeaderLevel::Leader => {
                let branch = branches.last_mut()?;
                match pair.code {
                    10 => branch.last_point = Some(point_at(pairs, index)),
                    11 => branch.dogleg = point_at(pairs, index),
                    40 => branch.dogleg_length = number(pair).unwrap_or(0.0),
                    _ => {}
                }
            }
            MLeaderLevel::Context => match pair.code {
                40 => scale = number(pair).unwrap_or(1.0),
                41 => text.height = number(pair).unwrap_or(0.0),
                140 => context_arrow = number(pair).unwrap_or(0.0),
                290 => has_text = number(pair) == Some(1.0),
                304 => text.value = marker.unwrap_or_default(),
                11 => text.normal = point_at(pairs, index),
                340 => text.style_handle = handle(pair),
                12 => text.location = point_at(pairs, index),
                13 => text.direction = point_at(pairs, index),
                43 => text.width = number(pair).unwrap_or(0.0),
                45 => text.line_spacing_factor = number(pair).unwrap_or(1.0),
                90 => text.color = CmColor::from_raw(number(pair).unwrap_or(0.0) as i64),
                171 => text.alignment = number(pair).unwrap_or(1.0) as i16,
                296 => has_block = number(pair) == Some(1.0),
                341 => block.block_handle = handle(pair).unwrap_or(0),
                14 => block.normal = point_at(pairs, index),
                15 => block.location = point_at(pairs, index),
                16 => block.scale = point_at(pairs, index),
                46 => block.rotation = number(pair).unwrap_or(0.0),
                93 => block.color = CmColor::from_raw(number(pair).unwrap_or(0.0) as i64),
                _ => {}
            },
            MLeaderLevel::Top if seen_context => match pair.code {
                170 => {
                    path = match number(pair).unwrap_or(1.0) as i64 {
                        0 => LeaderPath::Invisible,
                        2 => LeaderPath::Spline,
                        _ => LeaderPath::Straight,
                    }
                }
                91 => line_color = CmColor::from_raw(number(pair).unwrap_or(0.0) as i64),
                291 => dogleg_enabled = number(pair) != Some(0.0),
                342 => arrow_handle = handle(pair),
                42 => arrow_size = number(pair).unwrap_or(0.0),
                344 => top_block_handle = handle(pair),
                _ => {}
            },
            MLeaderLevel::Top => {}
        }
    }
    if !seen_context {
        return None;
    }
    if block.block_handle == 0 {
        block.block_handle = top_block_handle.unwrap_or(0);
    }
    let arrowhead_size = if context_arrow > 0.0 {
        context_arrow
    } else {
        arrow_size * scale
    };
    Some(RawMLeader {
        common,
        model: MLeaderModel {
            branches,
            path,
            line_color,
            dogleg_enabled,
            arrowhead_size,
            arrowhead_handle: arrow_handle,
            text: (has_text && !text.value.is_empty()).then_some(text),
            block: (has_block && block.block_handle != 0).then_some(block),
        },
    })
}
