/**
 * 파일 뷰어 플러그인 목록(앱에 번들되는 기본 뷰어).
 *
 * 뷰어를 추가하려면 이 폴더에 .js 파일을 만들고 아래 배열에 파일명을 넣는다.
 * (file:// 로 로드되므로 fetch/XHR 로 폴더를 훑을 수 없다 — 그래서 JSON 이 아니라
 *  이렇게 JS 목록으로 둔다. index.html 은 이 배열을 보고 각 파일을 주입한다.)
 *
 * ── 사용자가 추가하는 뷰어 ────────────────────────────────────────────────
 * 앱을 다시 빌드하지 않고 얹으려면 **설정 → 뷰어**에서 .js 파일을
 * 추가한다(앱에 담긴 예제는 `examples/` — 목록의 버튼으로 바로 추가된다).
 * 네이티브가 그 파일을 웹 루트(`viewers/user/`)로 복사한 뒤
 * `collaboSyncUserViewers([...])` 로 넘기고, 여기 있는 뷰어들과 똑같이 등록된다.
 * 계약도 동일하다. 단 **register 는 스크립트 최상위에서 호출할 것** —
 * 어느 파일이 등록했는지를 `document.currentScript` 로 기록해 두고, 설정에서
 * 제거할 때 그 기준으로 내리기 때문이다(비동기 콜백 안에서 부르면 못 내린다).
 *
 * ── 플러그인 계약 ─────────────────────────────────────────────────────────
 * collaboViewers.register({
 *   id:         'markdown',        // 고유 식별자(필수)
 *   label:      'Markdown',        // 드롭다운에 보일 이름(필수)
 *   dataMode:   'text',            // 네이티브에 요청할 읽기 형태:
 *                                  //  'text'(1MB) | 'hex'(256KB) | 'archive'(목록 JSON)
 *   extensions: ['.md'],           // (선택) 담당 확장자. **선언하면 그 확장자에만
 *                                  //  후보가 된다.** 비우면 담당 확장자가 없고,
 *                                  //  아무도 담당하지 않는 파일의 폴백으로만 쓰인다.
 *                                  //  사용자가 설정 → 뷰어에서 덮어쓸 수 있다.
 *   match(info) { ... },           // (선택) {path, ext, dataMode} → bool
 *   render(ctx) { ... },           // 필수. ctx 안으로 그린다
 * });
 *
 * 같은 확장자를 여러 뷰어가 담당하면 **목록에서 위에 있는 뷰어가 이긴다**. 기본 순서는
 * 아래 배열 순서(사용자 뷰어는 그 뒤)이고, 사용자가 설정 → 뷰어에서 끌어 바꾼다.
 * 플러그인이 스스로 우선순위를 주장하는 값은 없다.
 *
 * render(ctx) 의 ctx:
 *   el         뷰어 컨테이너 엘리먼트(이 안을 채운다. className 도 뷰어가 정한다)
 *   content    네이티브가 읽어 준 문자열(dataMode 형태)
 *   path       파일 전체 경로
 *   size       파일 전체 크기(바이트)
 *   truncated  상한 때문에 앞부분만 왔는지 — **true 면 저장하면 안 된다**
 *              (뒷부분이 없는 채로 덮어쓰게 된다)
 *   windowed   상한을 넘지만 **줄 단위로 이어 읽을 수 있는** 파일인지(text/hex).
 *              true 면 content 는 여전히 앞부분이고, 나머지는 window() 로 받는다.
 *   lineCount  파일 전체 줄 수(hex 는 16바이트 = 한 줄). windowed 일 때만 의미 있음
 *   window(from, count)  줄 창 하나를 읽는다(0-based, 한 번에 최대 2000줄)
 *              → Promise<{path, mode, from, lines:[...], lineCount, error?}>
 *   util       { esc(s), baseName(p), extOf(p), t(key, fallback) } 공용 도우미
 *   save(text, done)  파일을 덮어쓴다. 쓰기도 네이티브가 대행하며(`file.save`),
 *              done(ok, error) 로 결과가 온다. 프로젝트 밖 경로는 거부된다.
 *              편집기 예제는 `markdown-editor.js` 참고.
 *   ── 큰 파일 그리기 ──
 *   직접 window() 를 붙잡고 스크롤을 계산할 필요는 없다. 공용 가상 스크롤을 쓴다:
 *
 *     if (ctx.windowed && ctx.window) {
 *       collaboViewers.virtualList(ctx, { className: 'hex-view' });  // 옵션 생략 가능
 *       return;
 *     }
 *
 *   전체 줄 수만큼 높이를 잡아 두고(스크롤바가 파일 전체를 나타낸다) 보이는 줄만
 *   그린다. 기본 Text/Hex 뷰어가 이 방식으로 동작한다(`text.js`, `hex.js`).
 *   ⚠️ 화면에 없는 줄은 DOM 에도 없다 — 내용 검색 하이라이트는 **보이는 부분에만**
 *   걸린다(파일 전체 검색은 도구 계층의 `search_text` 가 한다).
 *
 *   entry(name)  **dataMode 'archive' 전용.** 압축 안의 파일 하나를 읽는다.
 *              → Promise<{name, mode:'text'|'hex', content, size, truncated, error?}>
 *              그 항목만 그때 풀기 때문에(아이솔레이트) 목록은 가볍게 유지된다.
 *
 * ── 여러 파일로 된 뷰어(WASM 등) ──────────────────────────────────────────
 * 설정 → 뷰어에서 **폴더**를 고르면 그 폴더가 통째로 얹힌다. 폴더에 `viewer.json`
 * 이 있어야 한다:
 *
 *   { "entry": "main.js", "scripts": ["lib/dep.js"], "assets": ["mod.wasm"] }
 *
 * `scripts` → `entry` 순서로 **차례로** 로드된다(순서가 곧 의존성). `assets` 는
 * 로드하지 않고 같이 복사만 되며, 바이트가 필요할 때 이렇게 읽는다:
 *
 *   collaboViewers.asset('my-viewer', 'mod.wasm')
 *     .then(function (bytes) { return WebAssembly.instantiate(bytes); })
 *
 * **`fetch`/`XHR` 은 쓸 수 없다** — 웹이 `file://` 로 로드되기 때문이다(그래서
 * `WebAssembly.instantiateStreaming` 도 안 된다). 위 API 는 네이티브가 파일을 읽어
 * base64 로 넘겨주고 `Uint8Array` 로 돌려준다. 읽을 수 있는 범위는 **그 뷰어가
 * 놓인 폴더 안**으로 제한된다(1건 32MB 상한).
 *
 * 주의:
 * - 웹은 OS 파일시스템에 직접 접근하지 않는다. 읽기는 항상 네이티브가 한다.
 *   그래서 새 데이터 형태(예: 이미지 바이트)가 필요하면 네이티브 FileService 에
 *   그 모드를 먼저 추가해야 한다(`FileViewMode`). 지금은 text / hex / archive.
 * - render 가 던지는 예외는 호출측이 잡아 오류 상자로 바꾼다(다른 뷰어는 안 죽는다).
 * - 내용 검색 하이라이트는 렌더 결과의 텍스트 노드를 훑는 방식이라, 어떤 DOM 을
 *   그리든 자동으로 동작한다.
 */
// 이 순서가 곧 **기본 우선순위**다(앞이 이긴다). 폴백(담당 확장자 없음)은
// 등급이 낮으므로 앞에 있어도 확장자를 담당하는 뷰어를 이기지 않는다.
//
// `examples/` 안의 파일은 여기에 없다 — **기본으로 붙지 않는** 예제이고,
// 설정 → 뷰어에서 추가하면 사용자 뷰어로 얹힌다(`examples/markdown-editor.js`).
window.COLLABO_VIEWER_FILES = [
  'markdown.js',
  'archive.js',
  'text.js',
  'hex.js',
];
