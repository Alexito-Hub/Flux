window.onerror = function(m, s, l, c, e) {
  var d = document.createElement('div');
  d.style.color = 'red';
  d.style.fontSize = '30px';
  d.style.background = 'white';
  d.style.position = 'absolute';
  d.style.zIndex = 9999;
  d.innerHTML = m + ' at ' + s + ':' + l;
  document.body.appendChild(d);
};
