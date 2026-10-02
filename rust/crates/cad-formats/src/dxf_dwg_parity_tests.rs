//! Cross-checks the DXF normalizer (pinned `dxf` reader + block expansion in
//! this crate) against the independent DWG path (acadrust reader + its INSERT
//! explosion) on one document written by acadrust in both formats.

use crate::{DwgAdapter, DxfAdapter};
use acadrust::entities::{
    Arc, AttributeEntity, BoundaryEdge, BoundaryPath, Circle, CircularArcEdge, Ellipse, Hatch,
    Insert, LineEdge, LwPolyline, PolylineEdge, Solid, Spline, Text,
};
use acadrust::entities::{
    MultiLeaderBuilder, MultiLeaderPathType, Table as AcadTable, TextAttachmentPointType,
};
use acadrust::tables::BlockRecord;
use acadrust::DxfWriter;
use acadrust::{CadDocument, DwgWriter, EntityType, Handle, Line, Vector2, Vector3};
use cad_core::{CancellationToken, Entity2DGeometry, FormatAdapter, Point2, SceneDocument};
use std::f64::consts::{FRAC_PI_2, PI, TAU};

fn owned(mut entity: EntityType, owner: Handle) -> EntityType {
    entity.common_mut().owner_handle = owner;
    entity
}

fn block(drawing: &mut CadDocument, name: &str, base: Vector3) -> Handle {
    let mut record = BlockRecord::new(name);
    record.handle = drawing.allocate_handle();
    record.base_point = base;
    let handle = record.handle;
    drawing.block_records.add(record).unwrap();
    handle
}

fn part_entities(owner: Handle) -> Vec<EntityType> {
    let mut mirrored_arc = Arc::new();
    mirrored_arc.center = Vector3::new(3.0, 4.0, 0.0);
    mirrored_arc.radius = 2.0;
    mirrored_arc.start_angle = 0.0;
    mirrored_arc.end_angle = FRAC_PI_2;
    mirrored_arc.normal = Vector3::new(0.0, 0.0, -1.0);
    let mut arc = Arc::new();
    arc.center = Vector3::new(5.0, 5.0, 0.0);
    arc.radius = 3.0;
    arc.start_angle = 0.2;
    arc.end_angle = 2.0;
    let mut outline = LwPolyline::new();
    outline.add_point_with_bulge(Vector2::new(0.0, 0.0), 0.5);
    outline.add_point_with_bulge(Vector2::new(4.0, 0.0), 0.0);
    outline.add_point_with_bulge(Vector2::new(4.0, 3.0), -0.3);
    outline.is_closed = true;
    let mut spline = Spline::from_control_points(
        3,
        vec![
            Vector3::new(0.0, 8.0, 0.0),
            Vector3::new(2.0, 11.0, 0.0),
            Vector3::new(5.0, 7.0, 0.0),
            Vector3::new(8.0, 10.0, 0.0),
        ],
    );
    spline.knots = vec![0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0];
    let mut hatch = Hatch::new();
    let mut polygon = PolylineEdge::new(Vec::new(), true);
    polygon.add_vertex(Vector2::new(10.0, 0.0), 0.4);
    polygon.add_vertex(Vector2::new(14.0, 0.0), 0.0);
    polygon.add_vertex(Vector2::new(14.0, 3.0), 0.0);
    let mut polygon_path = BoundaryPath::external();
    polygon_path.add_edge(BoundaryEdge::Polyline(polygon));
    hatch.add_path(polygon_path);
    let mut edges = BoundaryPath::new();
    edges.add_edge(BoundaryEdge::Line(LineEdge {
        start: Vector2::new(16.0, 0.0),
        end: Vector2::new(20.0, 0.0),
    }));
    edges.add_edge(BoundaryEdge::CircularArc(CircularArcEdge {
        center: Vector2::new(18.0, 0.0),
        radius: 2.0,
        start_angle: 0.0,
        end_angle: PI,
        counter_clockwise: true,
    }));
    hatch.add_path(edges);
    let mut label = Text::with_value("PART", Vector3::new(1.0, 2.0, 0.0));
    label.height = 1.0;
    vec![
        EntityType::Line(Line::from_coords(0.0, 0.0, 0.0, 10.0, 0.0, 0.0)),
        EntityType::Arc(arc),
        EntityType::Arc(mirrored_arc),
        EntityType::Circle(Circle::from_coords(1.0, 1.0, 0.0, 1.0)),
        EntityType::LwPolyline(outline),
        EntityType::Ellipse(Ellipse::from_center_axes(
            Vector3::new(6.0, 6.0, 0.0),
            Vector3::new(2.0, 0.5, 0.0),
            0.5,
        )),
        EntityType::Spline(spline),
        EntityType::Solid(Solid::new(
            Vector3::new(0.0, -3.0, 0.0),
            Vector3::new(2.0, -3.0, 0.0),
            Vector3::new(0.0, -1.0, 0.0),
            Vector3::new(2.0, -1.0, 0.0),
        )),
        EntityType::Hatch(hatch),
        EntityType::Text(label),
    ]
    .into_iter()
    .map(|entity| owned(entity, owner))
    .collect()
}

fn parity_document() -> CadDocument {
    let mut drawing = CadDocument::new();
    // acadrust's DXF writer always emits a (0, 0, 0) BLOCK base point, so base
    // points are covered by the authored DXF fixture instead.
    let part = block(&mut drawing, "PART", Vector3::ZERO);
    for entity in part_entities(part) {
        drawing.add_entity(entity).unwrap();
    }
    let assembly = block(&mut drawing, "ASSY", Vector3::ZERO);
    drawing
        .add_entity(owned(
            EntityType::Insert(
                Insert::new("PART", Vector3::new(5.0, 5.0, 0.0)).with_rotation(FRAC_PI_2),
            ),
            assembly,
        ))
        .unwrap();
    drawing
        .add_entity(owned(
            EntityType::Line(Line::from_coords(-1.0, -1.0, 0.0, -1.0, 6.0, 0.0)),
            assembly,
        ))
        .unwrap();
    let inserts = [
        Insert::new("PART", Vector3::new(100.0, 0.0, 0.0))
            .with_rotation(PI / 6.0)
            .with_uniform_scale(2.0),
        Insert::new("PART", Vector3::new(0.0, 100.0, 0.0)).with_scale(-1.0, 1.0, 1.0),
        Insert::new("PART", Vector3::new(200.0, 200.0, 0.0))
            .with_scale(1.0, 2.0, 1.0)
            .with_rotation(0.4),
        Insert::new("PART", Vector3::new(-50.0, -50.0, 0.0))
            .with_normal(Vector3::new(0.0, 0.0, -1.0))
            .with_rotation(0.3),
        Insert::new("ASSY", Vector3::new(300.0, 0.0, 0.0))
            .with_uniform_scale(0.5)
            .with_rotation(-0.7),
        Insert::new("PART", Vector3::new(0.0, -200.0, 0.0))
            .with_rotation(PI / 12.0)
            .with_array(2, 3, 30.0, 25.0),
    ];
    for insert in inserts {
        drawing.add_entity(EntityType::Insert(insert)).unwrap();
    }
    let mut tagged = Insert::new("PART", Vector3::new(400.0, 400.0, 0.0));
    tagged.attributes.push(
        AttributeEntity::new("NO".to_owned(), "A-17".to_owned())
            .with_position(Vector3::new(405.0, 395.0, 0.0))
            .with_height(2.0),
    );
    drawing.add_entity(EntityType::Insert(tagged)).unwrap();

    // A two-branch text MULTILEADER with doglegs and a block-content one.
    let mut note = MultiLeaderBuilder::new()
        .text("NOTE-7", Vector3::new(530.0, 60.0, 0.0))
        .leader_line(vec![
            Vector3::new(500.0, 0.0, 0.0),
            Vector3::new(510.0, 40.0, 0.0),
        ])
        .new_root()
        .leader_line(vec![Vector3::new(560.0, 0.0, 0.0)])
        .arrowhead_size(2.5)
        .text_height(3.0)
        .build();
    // acadrust's DXF writer stores the content type (2 for MTEXT) in group
    // 170, which the DXF reference and ezdxf define as the leader line type;
    // 2 means spline, so give this leader a spline path in both formats. The
    // authored DXF fixture covers group 170 independently.
    note.path_type = MultiLeaderPathType::Spline;
    note.enable_dogleg = true;
    note.dogleg_length = 4.0;
    for (root, (point, direction)) in note.context.leader_roots.iter_mut().zip([
        (Vector3::new(520.0, 55.0, 0.0), Vector3::new(1.0, 0.0, 0.0)),
        (Vector3::new(545.0, 55.0, 0.0), Vector3::new(-1.0, 0.0, 0.0)),
    ]) {
        root.connection_point = point;
        root.direction = direction;
        root.landing_distance = 4.0;
    }
    note.context.text_attachment_point = TextAttachmentPointType::Left;
    drawing.add_entity(EntityType::MultiLeader(note)).unwrap();
    let mut balloon = MultiLeaderBuilder::new()
        .block(part, Vector3::new(600.0, 50.0, 0.0))
        .leader_line(vec![Vector3::new(590.0, 0.0, 0.0)])
        .arrowhead_size(2.0)
        .build();
    balloon.enable_dogleg = false;
    balloon.context.leader_roots[0].connection_point = Vector3::new(598.0, 45.0, 0.0);
    balloon.context.block_content_location = Vector3::new(600.0, 50.0, 0.0);
    balloon.context.block_content_scale = Vector3::new(1.0, 1.0, 1.0);
    balloon.context.block_rotation = 0.5;
    drawing
        .add_entity(EntityType::MultiLeader(balloon))
        .unwrap();

    // A rotated table whose anonymous block holds its grid and cell text.
    let grid = block(&mut drawing, "*T1", Vector3::ZERO);
    for (x1, y1, x2, y2) in [
        (0.0, 0.0, 30.0, 0.0),
        (0.0, -8.0, 30.0, -8.0),
        (0.0, -16.0, 30.0, -16.0),
        (0.0, 0.0, 0.0, -16.0),
        (15.0, 0.0, 15.0, -16.0),
        (30.0, 0.0, 30.0, -16.0),
    ] {
        drawing
            .add_entity(owned(
                EntityType::Line(Line::from_coords(x1, y1, 0.0, x2, y2, 0.0)),
                grid,
            ))
            .unwrap();
    }
    let mut cell = Text::with_value("CELL", Vector3::new(2.0, -6.0, 0.0));
    cell.height = 2.0;
    drawing
        .add_entity(owned(EntityType::Text(cell), grid))
        .unwrap();
    let mut table = AcadTable::new(Vector3::new(700.0, 100.0, 0.0), 2, 2);
    table.block_record_handle = Some(grid);
    table.horizontal_direction = Vector3::new(0.2f64.cos(), 0.2f64.sin(), 0.0);
    drawing.add_entity(EntityType::Table(table)).unwrap();
    drawing
}

/// Dense world-space polylines for every non-text entity, plus text labels.
fn sample(document: SceneDocument) -> (Vec<Vec<Point2>>, Vec<(String, Point2)>) {
    let SceneDocument::TwoD(scene) = document else {
        panic!("expected a 2D scene")
    };
    let mut paths = Vec::new();
    let mut labels = Vec::new();
    let arc = |center: Point2, radius: f64, start: f64, sweep: f64| {
        (0..=120)
            .map(|index| {
                let angle = start + sweep * index as f64 / 120.0;
                Point2::new(
                    center.x + radius * angle.cos(),
                    center.y + radius * angle.sin(),
                )
            })
            .collect::<Vec<_>>()
    };
    for entity in scene.entities {
        match entity.geometry {
            Entity2DGeometry::Point { position } => paths.push(vec![position]),
            Entity2DGeometry::Line { start, end } => paths.push(vec![start, end]),
            Entity2DGeometry::Polyline { mut points, closed } => {
                if closed && !points.is_empty() {
                    points.push(points[0]);
                }
                paths.push(points);
            }
            Entity2DGeometry::Circle { center, radius } => {
                paths.push(arc(center, radius, 0.0, TAU))
            }
            Entity2DGeometry::Arc {
                center,
                radius,
                start_angle,
                end_angle,
            } => {
                let mut sweep = (end_angle - start_angle).rem_euclid(TAU);
                if sweep <= 1e-12 {
                    sweep = TAU;
                }
                paths.push(arc(center, radius, start_angle, sweep));
            }
            Entity2DGeometry::Text { origin, value, .. } => labels.push((value, origin)),
        }
    }
    (paths, labels)
}

fn distance_to_paths(point: Point2, paths: &[Vec<Point2>]) -> f64 {
    let mut best = f64::INFINITY;
    for path in paths {
        if path.len() == 1 {
            best = best.min((point.x - path[0].x).hypot(point.y - path[0].y));
        }
        for segment in path.windows(2) {
            let (a, b) = (segment[0], segment[1]);
            let (dx, dy) = (b.x - a.x, b.y - a.y);
            let length = dx * dx + dy * dy;
            let t = if length == 0.0 {
                0.0
            } else {
                (((point.x - a.x) * dx + (point.y - a.y) * dy) / length).clamp(0.0, 1.0)
            };
            best = best.min((point.x - a.x - t * dx).hypot(point.y - a.y - t * dy));
        }
    }
    best
}

/// Largest distance from any vertex (and segment midpoint) of [from] to [to].
fn directed_hausdorff(from: &[Vec<Point2>], to: &[Vec<Point2>]) -> (f64, Point2) {
    let mut worst = (0.0, Point2::new(0.0, 0.0));
    for path in from {
        let mut probes = path.clone();
        probes.extend(path.windows(2).map(|segment| {
            Point2::new(
                (segment[0].x + segment[1].x) / 2.0,
                (segment[0].y + segment[1].y) / 2.0,
            )
        }));
        for point in probes {
            let distance = distance_to_paths(point, to);
            if distance > worst.0 {
                worst = (distance, point);
            }
        }
    }
    worst
}

#[test]
fn dxf_block_expansion_matches_the_independent_dwg_path() {
    let drawing = parity_document();
    let directory = tempfile::tempdir().unwrap();
    let dwg_path = directory.path().join("parity.dwg");
    DwgWriter::write_to_file(&dwg_path, &drawing).unwrap();
    let dwg = DwgAdapter
        .open_path(&dwg_path, "parity.dwg", &CancellationToken::default(), None)
        .unwrap();
    let (dwg_paths, mut dwg_labels) = sample(dwg.scene);

    for binary in [false, true] {
        let mut writer = DxfWriter::new(&drawing);
        writer.set_binary(binary);
        let bytes = writer.write_to_vec().unwrap();
        let dxf = DxfAdapter
            .open(
                &bytes,
                "parity.dxf",
                None,
                &CancellationToken::default(),
                None,
            )
            .unwrap();
        let unsupported = dxf
            .diagnostics
            .iter()
            .filter(|diagnostic| diagnostic.code == "dxf.unsupported_entities")
            .map(|diagnostic| diagnostic.message.clone())
            .collect::<Vec<_>>();
        assert!(unsupported.is_empty(), "{unsupported:?}");
        let (dxf_paths, mut dxf_labels) = sample(dxf.scene);
        // Every PART instance (9 direct incl. 6 array cells, 1 nested) and
        // the nested ASSY line must be present: compare both directions.
        let (forward, at) = directed_hausdorff(&dxf_paths, &dwg_paths);
        assert!(
            forward < 0.05,
            "binary={binary}: DXF point {at:?} is {forward} from DWG"
        );
        let (backward, at) = directed_hausdorff(&dwg_paths, &dxf_paths);
        assert!(
            backward < 0.05,
            "binary={binary}: DWG point {at:?} is {backward} from DXF"
        );

        let key = |labels: &mut Vec<(String, Point2)>| {
            labels.sort_by(|a, b| {
                (a.0.as_str(), a.1.x, a.1.y)
                    .partial_cmp(&(b.0.as_str(), b.1.x, b.1.y))
                    .unwrap()
            });
        };
        key(&mut dxf_labels);
        key(&mut dwg_labels);
        assert_eq!(
            dxf_labels.len(),
            dwg_labels.len(),
            "{dxf_labels:?} vs {dwg_labels:?}"
        );
        assert!(dxf_labels.iter().any(|label| label.0 == "A-17"));
        assert!(dxf_labels
            .iter()
            .any(|label| label.0 == "NOTE-7" && (label.1.x - 530.0).abs() < 1e-9));
        // Table cell (2, -6) rotated by 0.2 rad about the table origin.
        let (sin, cos) = 0.2f64.sin_cos();
        let cell = Point2::new(700.0 + 2.0 * cos + 6.0 * sin, 100.0 + 2.0 * sin - 6.0 * cos);
        assert!(
            dxf_labels.iter().any(|label| label.0 == "CELL"
                && (label.1.x - cell.x).abs() < 1e-9
                && (label.1.y - cell.y).abs() < 1e-9),
            "{dxf_labels:?}"
        );
        for (dxf_label, dwg_label) in dxf_labels.iter().zip(&dwg_labels) {
            assert_eq!(dxf_label.0, dwg_label.0);
            assert!(
                (dxf_label.1.x - dwg_label.1.x).abs() < 1e-6
                    && (dxf_label.1.y - dwg_label.1.y).abs() < 1e-6,
                "{dxf_label:?} vs {dwg_label:?}"
            );
        }
    }
}
