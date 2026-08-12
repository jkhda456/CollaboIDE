/** 마크다운 뷰어. 렌더는 번들된 marked 를 쓴다(없으면 원문을 그대로 보여준다). */
collaboViewers.register({
  id: 'markdown',
  label: 'Markdown',
  dataMode: 'text',
  extensions: ['.md', '.markdown'],
  render: function (ctx) {
    ctx.el.className = 'p-3 md-rendered';
    if (window.marked) {
      ctx.el.innerHTML = marked.parse(ctx.content);
    } else {
      // marked 가 없으면 원문을 그대로(이스케이프해서) 보여준다.
      ctx.el.innerHTML = '<pre>' + ctx.util.esc(ctx.content) + '</pre>';
    }
  },
});
