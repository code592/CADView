//! SQLite persistence for local, source-file-independent annotations.

use cad_core::{Annotation, AnnotationDocument};
use rusqlite::{params, Connection};
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("annotation JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

pub struct AnnotationStore {
    connection: Connection,
}

impl AnnotationStore {
    pub fn open(path: &Path) -> Result<Self, StorageError> {
        let connection = Connection::open(path)?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA foreign_keys=ON;
             CREATE TABLE IF NOT EXISTS annotation_documents (
                 source_fingerprint TEXT PRIMARY KEY NOT NULL,
                 schema_version INTEGER NOT NULL,
                 updated_at_epoch_ms INTEGER NOT NULL DEFAULT 0
             );
             CREATE TABLE IF NOT EXISTS annotations (
                 source_fingerprint TEXT NOT NULL,
                 annotation_id TEXT NOT NULL,
                 payload_json TEXT NOT NULL,
                 updated_at_epoch_ms INTEGER NOT NULL,
                 PRIMARY KEY (source_fingerprint, annotation_id),
                 FOREIGN KEY (source_fingerprint)
                   REFERENCES annotation_documents(source_fingerprint)
                   ON DELETE CASCADE
             );",
        )?;
        Ok(Self { connection })
    }

    pub fn replace_document(&mut self, document: &AnnotationDocument) -> Result<(), StorageError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO annotation_documents(source_fingerprint, schema_version, updated_at_epoch_ms)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(source_fingerprint) DO UPDATE SET
               schema_version=excluded.schema_version,
               updated_at_epoch_ms=excluded.updated_at_epoch_ms",
            params![
                document.source_fingerprint,
                document.schema_version,
                document.annotations.iter().map(|item| item.updated_at_epoch_ms).max().unwrap_or(0),
            ],
        )?;
        transaction.execute(
            "DELETE FROM annotations WHERE source_fingerprint=?1",
            params![document.source_fingerprint],
        )?;
        for annotation in &document.annotations {
            transaction.execute(
                "INSERT INTO annotations(source_fingerprint, annotation_id, payload_json, updated_at_epoch_ms)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    document.source_fingerprint,
                    annotation.id.to_string(),
                    serde_json::to_string(annotation)?,
                    annotation.updated_at_epoch_ms,
                ],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn load_document(&self, fingerprint: &str) -> Result<AnnotationDocument, StorageError> {
        let schema_version = self
            .connection
            .query_row(
                "SELECT schema_version FROM annotation_documents WHERE source_fingerprint=?1",
                params![fingerprint],
                |row| row.get(0),
            )
            .unwrap_or(AnnotationDocument::SCHEMA_VERSION);
        let mut statement = self.connection.prepare(
            "SELECT payload_json FROM annotations
             WHERE source_fingerprint=?1 ORDER BY updated_at_epoch_ms, annotation_id",
        )?;
        let rows = statement.query_map(params![fingerprint], |row| row.get::<_, String>(0))?;
        let mut annotations = Vec::<Annotation>::new();
        for row in rows {
            annotations.push(serde_json::from_str(&row?)?);
        }
        Ok(AnnotationDocument {
            schema_version,
            source_fingerprint: fingerprint.to_owned(),
            annotations,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cad_core::{AnnotationAnchor, AnnotationGeometry, Point2};
    use uuid::Uuid;

    #[test]
    fn sqlite_round_trip_is_scoped_by_fingerprint() {
        let directory = tempfile::tempdir().unwrap();
        let mut store = AnnotationStore::open(&directory.path().join("notes.sqlite3")).unwrap();
        let mut document = AnnotationDocument::new("drawing-a".to_owned());
        document.annotations.push(Annotation {
            id: Uuid::new_v4(),
            author: None,
            color_argb: 0xffffcc00,
            geometry: AnnotationGeometry::Text {
                anchor: AnnotationAnchor {
                    entity_path: Some("layer/1/entity/7".to_owned()),
                    local_parameter: None,
                    world_2d: Some(Point2::new(1.0, 2.0)),
                    world_3d: None,
                },
                value: "check".to_owned(),
            },
            created_at_epoch_ms: 1,
            updated_at_epoch_ms: 2,
        });
        store.replace_document(&document).unwrap();

        let loaded = store.load_document("drawing-a").unwrap();
        assert_eq!(loaded.annotations.len(), 1);
        assert!(store
            .load_document("drawing-b")
            .unwrap()
            .annotations
            .is_empty());
    }
}
