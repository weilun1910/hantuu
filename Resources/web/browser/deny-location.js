(() => {
  'use strict';
  // Return a quiet denial without opening a system prompt. The app has no location
  // usage description, and macOS 27 also has an explicit native denial callback.
  const geo = navigator.geolocation;
  if (!geo) return;
  const denied = (_success, failure) => {
    if (typeof failure === 'function') queueMicrotask(() => failure({code:1,message:'Location is disabled in this browser.',PERMISSION_DENIED:1}));
    return 0;
  };
  for (const target of [Object.getPrototypeOf(geo), geo]) {
    for (const name of ['getCurrentPosition','watchPosition']) {
      try { Object.defineProperty(target,name,{value:denied,writable:false,configurable:false}); } catch (_) {}
    }
    try { Object.defineProperty(target,'clearWatch',{value:()=>{},writable:false,configurable:false}); } catch (_) {}
  }
})();
