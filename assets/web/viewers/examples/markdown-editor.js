/**
 * 마크다운 편집기 — **추가로 얹는 에디터** 예제.
 *
 * 기본 뷰어가 아니다. 설정 → 뷰어에서 추가해야 붙는다(앱에 예제로 담겨 있으니
 * 목록의 "추가" 버튼 한 번으로 얹힌다). 사용자가 만든 뷰어와 완전히 같은 취급을
 * 받으므로, 새 뷰어를 만들 때 이 파일을 복사해서 시작하면 된다.
 *
 * 읽기 전용 뷰어(markdown.js)와 달리 `ctx.save(text, done)` 로 파일을 저장한다.
 * 웹은 파일시스템에 직접 접근하지 않으므로, 저장도 네이티브(`file.save`)가 대행한다.
 *
 * 얹어도 `.md` 의 기본은 읽기 전용 Markdown 뷰어다(목록에서 위) — 파일을 여는 것만으로
 * 편집 모드가 되는 건 위험하다. 편집하려면 뷰어 헤더의 보기 방식 드롭다운에서 고르고,
 * 늘 편집기로 열고 싶으면 설정 → 뷰어에서 이 뷰어를 Markdown 위로 끌어 올린다.
 */
(function () {
  // 저장하지 않은 편집분(경로 → 텍스트). 뷰어는 파일이 바뀌거나 보기 방식을
  // 오갈 때 통째로 다시 render 되므로, 편집 중 내용은 render 밖에 둬야 살아남는다.
  var drafts = Object.create(null);

  collaboViewers.register({
    id: 'markdown-editor',
    label: 'Markdown (edit)',
    dataMode: 'text',
    extensions: ['.md', '.markdown'],

    render: function (ctx) {
      var t = ctx.util.t;
      // 저장 후 기준선(디스크에 있는 내용). 저장에 성공하면 여기를 갱신한다.
      var base = ctx.content;
      var draft = drafts[ctx.path];
      var restored = draft != null && draft !== base;
      if (!restored) delete drafts[ctx.path];

      ctx.el.className = 'md-editor';
      ctx.el.innerHTML = '';

      // ── 툴바 ──────────────────────────────────────────────────────────
      var bar = document.createElement('div');
      bar.className = 'md-editor-bar';
      var saveBtn = document.createElement('button');
      saveBtn.type = 'button';
      saveBtn.className = 'btn btn-sm btn-primary';
      saveBtn.textContent = t('save', '저장');
      var state = document.createElement('span');
      state.className = 'md-editor-state text-secondary';
      bar.appendChild(saveBtn);
      bar.appendChild(state);
      ctx.el.appendChild(bar);

      function warnBar(text) {
        var el = document.createElement('div');
        el.className = 'md-editor-warn alert alert-warning py-1 px-2 mb-0 small';
        el.textContent = text;
        ctx.el.appendChild(el);
        return el;
      }

      // 대용량 파일은 앞부분만 읽혀 있다 — 그대로 저장하면 뒷부분이 날아간다.
      if (ctx.truncated) {
        warnBar(t('editorNoSaveTruncated',
          '앞부분만 읽은 대용량 파일입니다 — 저장하면 뒷부분이 사라지므로 저장을 막았습니다.'));
        saveBtn.disabled = true;
      }

      // ── 편집 + 미리보기 ───────────────────────────────────────────────
      var split = document.createElement('div');
      split.className = 'md-editor-split';
      var area = document.createElement('textarea');
      area.className = 'md-editor-input';
      area.spellcheck = false;
      area.value = restored ? draft : base;
      var preview = document.createElement('div');
      preview.className = 'md-editor-preview md-rendered';
      split.appendChild(area);
      split.appendChild(preview);
      ctx.el.appendChild(split);

      if (restored) {
        var note = warnBar(t('editorRestoredDraft',
          '저장하지 않은 편집 내용을 복원했습니다. 저장하면 디스크의 내용을 덮어씁니다.'));
        var reload = document.createElement('button');
        reload.type = 'button';
        reload.className = 'btn btn-sm btn-link p-0 ms-2 align-baseline';
        reload.textContent = t('editorReloadDisk', '디스크 내용 불러오기');
        reload.addEventListener('click', function () {
          area.value = base;
          onInput();
          note.remove();
        });
        note.appendChild(reload);
        // 경고는 툴바 바로 아래로.
        ctx.el.insertBefore(note, split);
      }

      function renderPreview() {
        if (window.marked) {
          preview.innerHTML = marked.parse(area.value);
        } else {
          preview.innerHTML = '<pre>' + ctx.util.esc(area.value) + '</pre>';
        }
      }

      function onInput() {
        var dirty = area.value !== base;
        if (dirty) drafts[ctx.path] = area.value; else delete drafts[ctx.path];
        state.textContent = dirty ? t('unsaved', '저장 안 됨') : '';
        renderPreview();
      }

      function save() {
        if (saveBtn.disabled || area.value === base) return;
        var sent = area.value;
        saveBtn.disabled = true;
        state.textContent = t('saving', '저장 중…');
        ctx.save(sent, function (ok, error) {
          saveBtn.disabled = false;
          if (!ok) {
            // 실패하면 편집분을 그대로 남긴다 — 다시 시도할 수 있어야 한다.
            state.textContent = t('saveFailed', '저장 실패') + (error ? ': ' + error : '');
            return;
          }
          base = sent;                       // 새 기준선 = 방금 디스크에 쓴 내용
          if (area.value === base) {
            delete drafts[ctx.path];
            state.textContent = t('saved', '저장됨');
          } else {
            state.textContent = t('unsaved', '저장 안 됨');   // 저장 중에 더 고쳤다
          }
        });
      }

      area.addEventListener('input', onInput);
      // Ctrl/Cmd+S 저장. 브라우저 기본 동작(페이지 저장)은 막는다.
      area.addEventListener('keydown', function (e) {
        if ((e.ctrlKey || e.metaKey) && (e.key === 's' || e.key === 'S')) {
          e.preventDefault();
          save();
        }
      });
      saveBtn.addEventListener('click', save);

      onInput();
    },
  });
})();
