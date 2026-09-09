/**
 * 기본 텍스트 뷰어. 담당 확장자를 선언하지 않으므로, **아무 뷰어도 담당하지 않는
 * 텍스트 파일의 폴백**으로 쓰인다(확장자를 담당하는 뷰어가 있으면 그쪽이 이긴다).
 *
 * 큰 파일(ctx.windowed)은 전체를 받지 않고 **보이는 줄만** 그린다.
 */
collaboViewers.register({
  id: 'text',
  label: 'Text',
  dataMode: 'text',
  render: function (ctx) {
    // 상한을 넘는 파일은 가상 스크롤 — 스크롤바는 파일 전체를 나타내고,
    // 화면에 필요한 줄만 네이티브에서 그때그때 받아 온다.
    if (ctx.windowed && ctx.window) {
      collaboViewers.virtualList(ctx);
      return;
    }
    // 패딩은 pre 가 가진다 — 스크롤 컨테이너에 패딩을 주면 가로 스크롤 시 어긋난다.
    ctx.el.className = '';
    var pre = document.createElement('pre');
    pre.textContent = ctx.content;
    ctx.el.innerHTML = '';
    ctx.el.appendChild(pre);
  },
});
