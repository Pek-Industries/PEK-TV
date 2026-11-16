/// The page that plays a trailer as a plain video from this app's own server (`/api/trailer`): no YouTube page, no YouTube scripts.
/// Shared by every host's web view: Android's WebView (`PekTrailer` channel) and Windows' WebView2 (`chrome.webview.postMessage`)
/// both hear "error" when the video cannot play. The page also answers `post({event:'command',func:'playVideo'|'pauseVideo'})`.
/// [audio] is empty when the server sends picture and sound as one stream.
String trailerPageHtml({required String video, required String audio, required bool play, required bool muted, required bool seeThrough}) {
  final bg = seeThrough ? 'transparent' : '#000';
  final css = 'html,body{margin:0;height:100%;background:$bg;overflow:hidden}'
      'video{position:absolute;left:0;top:0;width:100%;height:100%;object-fit:cover;pointer-events:none;opacity:0;transition:opacity .4s}'
      'video.on{opacity:1}'
      'video::-webkit-media-controls,video::-webkit-media-controls-start-playback-button,video::-webkit-media-controls-overlay-play-button,video::-webkit-media-controls-panel{display:none!important;-webkit-appearance:none}';
  final js = "var v=document.getElementById('v'),a=document.getElementById('a'),want=${play ? 'true' : 'false'},muted=${muted ? 'true' : 'false'},ok=false;"
      "function bad(){if(!ok){ok=true;try{PekTrailer.postMessage('error')}catch(e){try{window.chrome.webview.postMessage('error')}catch(e2){}}}}"
      "v.muted=a?true:muted;if(a)a.muted=muted;"
      "function go(){if(!want)return;var p=v.play();if(p&&p.catch)p.catch(function(){});if(a){var q=a.play();if(q&&q.catch)q.catch(function(){})}}"
      "function stop(){v.pause();if(a)a.pause()}"
      "function post(o){if(!o||o.event!=='command')return;if(o.func==='playVideo'){want=true;go()}else if(o.func==='pauseVideo'){want=false;stop()}}"
      "v.addEventListener('playing',function(){ok=true;v.className='on'});"
      "v.addEventListener('error',bad);if(a)a.addEventListener('error',bad);"
      "if(a){setInterval(function(){if(v.paused||v.readyState<3)return;if(Math.abs(a.currentTime-v.currentTime)>0.35)a.currentTime=v.currentTime;if(a.paused&&want)go()},400);"
      "v.addEventListener('waiting',function(){a.pause()});v.addEventListener('playing',function(){if(want)a.play().catch(function(){})})}"
      "setTimeout(function(){if(!ok)bad()},12000);go();";
  final html = '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
      '<style>$css</style></head><body>'
      '<video id="v" src="$video" loop playsinline preload="auto" poster="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" disablepictureinpicture controlslist="nodownload nofullscreen noremoteplayback"></video>'
      '${audio.isEmpty ? '' : '<audio id="a" src="$audio" loop preload="auto"></audio>'}'
      '<script>$js</script></body></html>';
  return html;
}
