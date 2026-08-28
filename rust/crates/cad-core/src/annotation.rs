use crate::{Point2, Point3};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnnotationAnchor {
    pub entity_path: Option<String>,
    pub local_parameter: Option<Vec<f64>>,
    pub world_2d: Option<Point2>,
    pub world_3d: Option<Point3>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AnnotationGeometry {
    Text {
        anchor: AnnotationAnchor,
        value: String,
    },
    Arrow {
        start: AnnotationAnchor,
        end: AnnotationAnchor,
    },
    Rectangle {
        first: AnnotationAnchor,
        second: AnnotationAnchor,
    },
    Cloud {
        points: Vec<AnnotationAnchor>,
    },
    Measurement {
        anchors: Vec<AnnotationAnchor>,
        value: f64,
        unit: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Annotation {
    pub id: Uuid,
    pub author: Option<String>,
    pub color_argb: u32,
    pub geometry: AnnotationGeometry,
    pub created_at_epoch_ms: i64,
    pub updated_at_epoch_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnnotationDocument {
    pub schema_version: u32,
    pub source_fingerprint: String,
    pub annotations: Vec<Annotation>,
}

impl AnnotationDocument {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn new(source_fingerprint: String) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            source_fingerprint,
            annotations: Vec::new(),
        }
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    pub fn from_json(value: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annotation_document_round_trips() {
        let document = AnnotationDocument::new("abc".to_owned());
        let json = document.to_json().unwrap();
        let decoded = AnnotationDocument::from_json(&json).unwrap();
        assert_eq!(decoded.schema_version, AnnotationDocument::SCHEMA_VERSION);
        assert_eq!(decoded.source_fingerprint, "abc");
    }
}
