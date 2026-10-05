// Data viewers' libraries (MarkView/Resources/Editor/vendor/js/markview-data.js): SQL over any
// table (sql.js, SQLite compiled to WebAssembly, with its wasm inlined so nothing is fetched),
// CSV/TSV parsing (papaparse), Parquet reading with every common codec (hyparquet) and YAML
// documents that keep their comments when edited (yaml), and unzipping Excel workbooks (fflate). Exposed as window.MVData.
import initSqlJs from 'sql.js/dist/sql-wasm.js';
import wasmBinary from 'sql.js/dist/sql-wasm.wasm';
import Papa from 'papaparse';
import { parquetMetadata, parquetSchema, parquetReadObjects } from 'hyparquet';
import { compressors } from 'hyparquet-compressors';
import * as YAML from 'yaml';
import { unzipSync, strFromU8 } from 'fflate';

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
  parquet: {
    metadata: (buffer) => parquetMetadata(buffer),
    schema: (metadata) => parquetSchema(metadata),
    /** Rows as objects; `rowEnd` limits how many are decoded. */
    rows: (buffer, options = {}) => parquetReadObjects({ file: buffer, compressors, ...options }),
  },
};
