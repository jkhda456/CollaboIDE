/**
 * 헥사 뷰어.
 *
 * 덤프 문자열(오프셋 + 바이트 + ASCII)은 **네이티브 FileService 가 만들어서** 준다
 * (`dataMode: 'hex'`, 상한 256KB). 여기서는 표시만 담당한다.
 */
collaboViewers.register({
  id: 'hex',
  label: 'Hex',
  dataMode: 'hex',
  // 담당 확장자 없음 = hex 로 읽혀 온 파일(바이너리 판정)의 폴백.
  render: function (ctx) {
    ctx.el.className = '';
    var pre = document.createElement('pre');
    pre.className = 'hex-view';
    pre.textContent = ctx.content;
    ctx.el.innerHTML = '';
    ctx.el.appendChild(pre);
  },
});
