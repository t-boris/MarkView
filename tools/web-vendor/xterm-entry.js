// xterm.js for MarkView's embedded terminals, exposed as the global `MVTerm`.
// Built by build.sh into Resources/Editor/vendor/js/xterm.bundle.js.
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";

window.MVTerm = { Terminal, FitAddon, WebLinksAddon };
