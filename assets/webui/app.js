// Beszel Monitor — 前端占位页（实际面板由 hub 二进制内嵌提供，
// 经 TOS nginx /beszelmonitor/ 路由访问；本页仅满足 webui.bz2 规范）
(function () {
  var target = '/beszelmonitor/';
  document.getElementById('link').href = target;
  setTimeout(function () { window.location.replace(target); }, 800);
})();
