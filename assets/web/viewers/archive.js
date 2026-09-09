/**
 * 압축 파일 뷰어 — 폴더 트리 + 항목 미리보기.
 *
 * `dataMode: 'archive'` 로 요청하면 네이티브(ArchiveService)가 압축을 해독해
 * **목록 JSON** 을 문자열로 준다. 항목 하나의 내용은 `ctx.entry(name)` 으로 따로
 * 요청한다(그때 네이티브가 아이솔레이트에서 그 항목만 풀어 준다).
 * 웹은 파일시스템에 접근하지 않으므로 압축 해독은 전부 네이티브가 한다.
 *
 * 받는 JSON:
 *   { format, entries:[{name,size,dir,mtime}], total, truncated, error? }
 *
 * 큰 파일은 네이티브가 상한을 걸어 거부하거나 목록을 잘라 준다 — 그때는 `error`
 * 또는 `truncated` 를 그대로 보여 준다(뷰어가 임의로 다시 시도하지 않는다).
 */
(function () {
  // 압축 파일마다 펼침/선택 상태를 기억한다. 뷰어는 파일 변경·보기 방식 전환 때
  // 통째로 다시 render 되므로, 상태를 render 밖에 둬야 살아남는다.
  var uiState = Object.create(null);   // 압축 경로 → {open:Set, selected:string}

  collaboViewers.register({
    id: 'archive',
    label: 'Archive',
    dataMode: 'archive',
    // 네이티브 ArchiveService._byExtension 과 맞춘 목록. 사용자가 설정 → 뷰어에서
    // 덮어쓸 수 있다(예: 사내 확장자 추가).
    //
    // 여기엔 **마지막 한 조각만** 적는다 — 뷰어 선택은 `extOf()`(마지막 점 뒤)로
    // 하므로 `.tar.gz` 는 `.gz` 로 잡히고, 그게 tar 인지는 네이티브가 판정한다
    // (`formatForPath` 가 복합 확장자를 본다).
    extensions: [
      '.zip', '.tar', '.tgz', '.tbz', '.tbz2', '.txz',
      '.gz', '.bz2', '.xz', '.zz',
      '.jar', '.war', '.apk', '.aab', '.ipa', '.whl', '.egg', '.xpi',
      '.vsix', '.crx', '.epub', '.odt', '.ods', '.odp',
      '.docx', '.xlsx', '.pptx',
    ],

    render: function (ctx) {
      var t = ctx.util.t;
      var state = uiState[ctx.path] || (uiState[ctx.path] = {
        open: Object.create(null),
        selected: null,
      });

      ctx.el.className = 'archive-view';
      ctx.el.innerHTML = '';

      var data;
      try {
        data = JSON.parse(ctx.content || '{}');
      } catch (e) {
        data = { error: String(e) };
      }

      // 열지 못한 경우(지원하지 않는 형식 / 너무 큼 / 깨짐): 이유를 그대로.
      if (data.error) {
        var err = document.createElement('div');
        err.className = 'p-3 text-danger small';
        err.textContent = data.error;
        ctx.el.appendChild(err);
        return;
      }

      var entries = data.entries || [];

      // ── 머리말: 형식 · 항목 수 · 검색 ────────────────────────────────────
      var bar = document.createElement('div');
      bar.className = 'archive-bar';
      var info = document.createElement('span');
      info.className = 'text-secondary text-nowrap';
      info.textContent = (data.format || '?') + ' · ' +
        (data.total || entries.length) + ' ' + t('archiveEntries', '항목');
      var filter = document.createElement('input');
      filter.type = 'search';
      filter.className = 'form-control form-control-sm archive-filter';
      filter.placeholder = t('archiveFilter', '이름으로 걸러내기…');
      bar.appendChild(info);
      bar.appendChild(filter);
      ctx.el.appendChild(bar);

      if (data.truncated) {
        var warn = document.createElement('div');
        warn.className = 'alert alert-warning py-1 px-2 mb-0 small';
        warn.textContent = t('archiveTruncated', '항목이 많아 일부만 표시합니다.') +
          ' (' + entries.length + '/' + data.total + ')';
        ctx.el.appendChild(warn);
      }

      var listEl = document.createElement('div');
      listEl.className = 'archive-list';
      ctx.el.appendChild(listEl);

      // ── 미리보기 판(항목을 고르면 아래에 펼쳐진다) ──────────────────────
      var preview = document.createElement('div');
      preview.className = 'archive-preview d-none';
      ctx.el.appendChild(preview);

      // ── 트리 만들기 ─────────────────────────────────────────────────────
      // 압축은 폴더 항목을 안 담을 수도 있어서(tar 등), 경로에서 폴더를 추론한다.
      var root = { name: '', path: '', dir: true, children: Object.create(null) };

      function nodeFor(pathParts, isDir, meta) {
        var node = root;
        for (var i = 0; i < pathParts.length; i++) {
          var part = pathParts[i];
          if (!part) continue;
          var last = i === pathParts.length - 1;
          var child = node.children[part];
          if (!child) {
            child = {
              name: part,
              path: (node.path ? node.path + '/' : '') + part,
              dir: last ? isDir : true,
              children: Object.create(null),
            };
            node.children[part] = child;
          }
          if (last && !isDir) {
            child.dir = false;
            child.size = meta.size;
            child.mtime = meta.mtime;
            child.entryName = meta.name;   // 네이티브에 넘길 원래 이름
          }
          node = child;
        }
        return node;
      }

      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var name = e.name || '';
        var isDir = !!e.dir || /\/$/.test(name);
        nodeFor(name.replace(/\/+$/, '').split('/'), isDir, e);
      }

      function sortedChildren(node) {
        var keys = Object.keys(node.children);
        keys.sort(function (a, b) {
          var x = node.children[a], y = node.children[b];
          if (x.dir !== y.dir) return x.dir ? -1 : 1;   // 폴더 먼저
          return a.toLowerCase() < b.toLowerCase() ? -1 : 1;
        });
        return keys.map(function (k) { return node.children[k]; });
      }

      // 작은 압축이면 전부 펼쳐 둔다(클릭 없이 바로 보이게).
      var autoOpen = entries.length <= 50;

      function isOpen(node) {
        if (node.path in state.open) return state.open[node.path];
        return autoOpen;
      }

      function fmtSize(n) {
        if (typeof n !== 'number' || n < 0) return '';
        if (n < 1024) return n + ' B';
        var units = ['KB', 'MB', 'GB', 'TB'];
        var v = n / 1024, i = 0;
        while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
        return (v < 10 ? v.toFixed(1) : Math.round(v)) + ' ' + units[i];
      }

      function fmtDate(ms) {
        if (!ms) return '';
        try {
          var d = new Date(ms);
          var pad = function (x) { return (x < 10 ? '0' : '') + x; };
          return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' +
            pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
        } catch (e) { return ''; }
      }

      /// 한 줄(폴더/파일)을 만든다.
      function rowFor(node, depth) {
        var row = document.createElement('div');
        row.className = 'archive-row' +
          (node.dir ? ' dir' : '') +
          (state.selected === node.entryName ? ' selected' : '');
        row.style.paddingLeft = (depth * 14 + 6) + 'px';

        var caret = document.createElement('span');
        caret.className = 'archive-caret';
        caret.textContent = node.dir ? (isOpen(node) ? '▾' : '▸') : '';
        row.appendChild(caret);

        var nameEl = document.createElement('span');
        nameEl.className = 'archive-name';
        nameEl.textContent = node.name;
        row.appendChild(nameEl);

        var meta = document.createElement('span');
        meta.className = 'archive-meta';
        meta.textContent = node.dir
          ? ''
          : fmtSize(node.size) + (node.mtime ? '  ' + fmtDate(node.mtime) : '');
        row.appendChild(meta);

        row.addEventListener('click', function () {
          if (node.dir) {
            state.open[node.path] = !isOpen(node);
            drawTree();
          } else {
            select(node);
          }
        });
        return row;
      }

      function drawSubtree(node, depth, into) {
        var children = sortedChildren(node);
        for (var i = 0; i < children.length; i++) {
          var child = children[i];
          into.appendChild(rowFor(child, depth));
          if (child.dir && isOpen(child)) drawSubtree(child, depth + 1, into);
        }
      }

      /// 걸러내기 중에는 트리 대신 **맞는 파일만** 평평하게 보여 준다.
      function drawFlat(query, into) {
        var q = query.toLowerCase();
        var shown = 0;
        for (var i = 0; i < entries.length; i++) {
          var e = entries[i];
          var name = e.name || '';
          if (e.dir || /\/$/.test(name)) continue;
          if (name.toLowerCase().indexOf(q) === -1) continue;
          var node = {
            name: name, path: name, dir: false,
            size: e.size, mtime: e.mtime, entryName: e.name,
            children: Object.create(null),
          };
          into.appendChild(rowFor(node, 0));
          if (++shown >= 500) break;   // 너무 많으면 그만(걸러내기를 더 좁히면 된다)
        }
        return shown;
      }

      function drawTree() {
        // 폴더를 접었다 펴면 목록을 다시 그리므로, 보고 있던 위치를 지켜 준다.
        var scroll = listEl.scrollTop;
        listEl.innerHTML = '';
        var q = filter.value.trim();
        var count = q ? drawFlat(q, listEl) : -1;
        if (!q) drawSubtree(root, 0, listEl);
        if (count === 0 || (!q && entries.length === 0)) {
          var empty = document.createElement('div');
          empty.className = 'p-2 text-secondary small';
          empty.textContent = q
            ? t('noResults', '검색 결과 없음')
            : t('archiveEmpty', '빈 압축 파일입니다.');
          listEl.appendChild(empty);
        }
        listEl.scrollTop = scroll;
      }

      // ── 미리보기 ────────────────────────────────────────────────────────
      function select(node) {
        state.selected = node.entryName;
        drawTree();
        showPreview(node);
      }

      function showPreview(node) {
        preview.classList.remove('d-none');
        preview.innerHTML = '';

        var head = document.createElement('div');
        head.className = 'archive-preview-head';
        var title = document.createElement('span');
        title.className = 'archive-preview-name';
        title.textContent = node.entryName;
        title.title = node.entryName;
        var close = document.createElement('button');
        close.type = 'button';
        close.className = 'btn-close btn-sm';
        close.title = t('close', '닫기');
        close.addEventListener('click', function () {
          state.selected = null;
          preview.classList.add('d-none');
          drawTree();
        });
        head.appendChild(title);
        head.appendChild(close);
        preview.appendChild(head);

        var body = document.createElement('div');
        body.className = 'archive-preview-body text-secondary small';
        body.textContent = t('viewerLoading', '파일을 읽는 중…');
        preview.appendChild(body);

        var wanted = node.entryName;
        ctx.entry(wanted).then(function (res) {
          // 그 사이 다른 항목을 골랐으면 버린다.
          if (state.selected !== wanted) return;
          body.className = 'archive-preview-body';
          body.innerHTML = '';
          if (!res || res.error) {
            body.className = 'archive-preview-body p-2 text-danger small';
            body.textContent = (res && res.error) || 'error';
            return;
          }
          if (res.truncated) {
            var note = document.createElement('div');
            note.className = 'alert alert-warning py-1 px-2 mb-0 small';
            note.textContent = t('truncated', '대용량 파일: 앞부분만 표시합니다') +
              ' (' + fmtSize(res.size) + ')';
            body.appendChild(note);
          }
          var pre = document.createElement('pre');
          if (res.mode === 'hex') pre.className = 'hex-view';
          pre.textContent = res.content || '';
          body.appendChild(pre);
        });
      }

      filter.addEventListener('input', drawTree);
      drawTree();
      // 이전에 보던 항목이 있으면 미리보기를 되살린다.
      if (state.selected) {
        var found = null;
        for (var j = 0; j < entries.length; j++) {
          if (entries[j].name === state.selected) {
            found = {
              name: entries[j].name, entryName: entries[j].name,
              size: entries[j].size, mtime: entries[j].mtime, dir: false,
            };
            break;
          }
        }
        if (found) showPreview(found); else state.selected = null;
      }
    },
  });
})();
