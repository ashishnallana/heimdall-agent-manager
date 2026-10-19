// Device request signing (docs/plans/passwordless-vault.md §2 P2 "Request signing").
//
//   X-Heimdall-Device-Sig over
//   heimdall-device-request/v1\n<METHOD>\n<path>\n<user_id>\n<ts>\n<nonce>\n<hex sha256(body)>
//
// The exact body bytes signed must be the bytes sent, so callers serialize once and
// pass the same string to the signer and to fetch.

import { signP256, toLowerHex } from './vaultStatements.ts';

export const DEVICE_REQUEST_HEADER = 'heimdall-device-request/v1';

export interface RequestSigner {
  readonly deviceId: string;
  readonly signPrivateKey: CryptoKey;
}

const utf8 = new TextEncoder();

export async function sha256HexOfText(text: string): Promise<string> {
  return toLowerHex(new Uint8Array(await crypto.subtle.digest('SHA-256', utf8.encode(text))));
}

export async function deviceRequestCanonical(method: string, path: string, userId: string, ts: number, nonce: string, body: string): Promise<string> {
  return [DEVICE_REQUEST_HEADER, method.toUpperCase(), path, userId, String(ts), nonce, await sha256HexOfText(body)].join('\n');
}

export function newRequestNonce(): string {
  return `n${toLowerHex(crypto.getRandomValues(new Uint8Array(16)))}`;
}

/** The four X-Heimdall-Device-* headers for one request. */
export async function signedRequestHeaders(
  signer: RequestSigner,
  userId: string,
  method: string,
  path: string,
  body: string = '',
  opts: { nonce?: string; ts?: number } = {},
): Promise<Record<string, string>> {
  const ts = opts.ts ?? Date.now();
  const nonce = opts.nonce ?? newRequestNonce();
  const canonical = await deviceRequestCanonical(method, path, userId, ts, nonce, body);
  return {
    'X-Heimdall-Device-Id': signer.deviceId,
    'X-Heimdall-Device-Ts': String(ts),
    'X-Heimdall-Device-Nonce': nonce,
    'X-Heimdall-Device-Sig': await signP256(signer.signPrivateKey, utf8.encode(canonical)),
  };
}
