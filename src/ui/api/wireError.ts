// The shared bridge<->hub error object (REQ-ERR-PROTO-A, src/contracts/errors.odin).
// Every failed bridge reply and every hub error envelope carries it:
//   code    coarse contract code (picks the HTTP status), e.g. "not_found"
//   class   what a caller may do: retry ("retriable"), wait for an outside fix
//           ("recoverable"), or give up ("fatal")
//   cause   the fine-grained reason, e.g. "path_not_found", "provider_not_logged_in"
//   message human text, for display only — never branch on it.
export type WireErrorClass = 'retriable' | 'recoverable' | 'fatal';

export type WireError = {
  code: string;
  class?: WireErrorClass | '';
  cause?: string;
  message: string;
  retry_after_ms?: number;
  scope?: string;
};
