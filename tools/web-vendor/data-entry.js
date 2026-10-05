// Data viewers' libraries (MarkView/Resources/Editor/vendor/js/markview-data.js): SQL over any
// table (sql.js, SQLite compiled to WebAssembly, with its wasm inlined so nothing is fetched),
// CSV/TSV parsing (papaparse), Parquet reading with every common codec (hyparquet) and YAML
// documents that keep their comments when edited (yaml), unzipping Excel and OpenDocument workbooks and
// Avro's deflate blocks (fflate), and Arrow IPC / Feather (apache-arrow). Exposed as window.MVData.
import initSqlJs from 'sql.js/dist/sql-wasm.js';
import wasmBinary from 'sql.js/dist/sql-wasm.wasm';
import Papa from 'papaparse';
import { parquetMetadata, parquetSchema, parquetReadObjects, snappyUncompress } from 'hyparquet';
import { compressors } from 'hyparquet-compressors';
import * as YAML from 'yaml';
import { unzipSync, strFromU8, inflateSync } from 'fflate';
import { tableFromIPC } from 'apache-arrow';

let sqlPromise = null;

window.MVData = {
  /** The SQL.js module (Database constructor), initialised once. */
  sql() {
    if (!sqlPromise) sqlPromise = initSqlJs({ wasmBinary });
    return sqlPromise;
  },
  Papa,
  YAML,
  /** Unzip an Office file (xlsx): path → bytes, and bytes → text. */
  unzip: (bytes) => unzipSync(bytes),
  text: (bytes) => strFromU8(bytes),
  /** Raw DEFLATE (Avro's deflate codec). */
  inflate: (bytes) => inflateSync(bytes),
  /** Snappy block → bytes (Avro's snappy codec, without its CRC). */
  snappy: (input, length) => { const out = new Uint8Array(length); snappyUncompress(input, out); return out; },
  /** An Arrow IPC file or stream (Feather v2): the apache-arrow Table. */
  arrowTable: (bytes) => tableFromIPC(bytes),
  parquet: {
    metadata: (buffer) => parquetMetadata(buffer),
    schema: (metadata) => parquetSchema(metadata),
    /** Rows as objects; `rowEnd` limits how many are decoded. */
    rows: (buffer, options = {}) => parquetReadObjects({ file: buffer, compressors, ...options }),
  },
};
