/* Service worker rahisi: inaruhusu app kuwekwa kwenye simu. Haihifadhi cache, kwa hiyo mashindano huwa mapya kila mara. */
self.addEventListener("install", function(){ self.skipWaiting(); });
self.addEventListener("activate", function(e){ e.waitUntil(self.clients.claim()); });
self.addEventListener("fetch", function(){});
