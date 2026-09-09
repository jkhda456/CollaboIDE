/**
 * 헥사 뷰어.
 *
 * 덤프 문자열(오프셋 + 바이트 + ASCII)은 **네이티브 FileService 가 만들어서** 준다
 * (`dataMode: 'hex'`, 상한 256KB). 여기서는 표시만 담당한다.
 *
 * 상한을 넘는 파일은 `ctx.windowed` 로 오고, 16바이트 = 한 줄이므로 스크롤 위치에
 * 해당하는 줄만 받아 그린다(주소 칸은 네이티브가 실제 오프셋으로 찍어 준다).
 */
collaboViewers.register({
  id: 'hex',
  label: 'Hex',
  dataMode: 'hex',
  // 담당 확장자 없음 = hex 로 읽혀 온 파일(바이너리 판정)의 폴백.
  render: function (ctx) {
    if (ctx.windowed && ctx.window) {
      collaboViewers.virtualList(ctx, { className: 'hex-view' });
      return;
    }
    ctx.el.className = '';
    var pre = document.createElement('pre');
    pre.className = 'hex-view';
    pre.textContent = ctx.content;
    ctx.el.innerHTML = '';
    ctx.el.appendChild(pre);
  },
});
