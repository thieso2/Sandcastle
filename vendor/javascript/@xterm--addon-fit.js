// @xterm/addon-fit@0.11.0 downloaded from https://ga.jspm.io/npm:@xterm/addon-fit@0.11.0/lib/addon-fit.mjs

/**
 * Copyright (c) 2014-2024 The xterm.js authors. All rights reserved.
 * @license MIT
 *
 * Copyright (c) 2012-2013, Christopher Jeffrey (MIT License)
 * @license MIT
 *
 * Originally forked from (with the author's permission):
 *   Fabrice Bellard's javascript vt100 for jslinux:
 *   http://bellard.org/jslinux/
 *   Copyright (c) 2011 Fabrice Bellard
 */
var e=2,t=1,r=class{activate(e){this._terminal=e}dispose(){}fit(){let e=this.proposeDimensions();if(!e||!this._terminal||isNaN(e.cols)||isNaN(e.rows))return;let t=this._terminal._core;(this._terminal.rows!==e.rows||this._terminal.cols!==e.cols)&&(t._renderService.clear(),this._terminal.resize(e.cols,e.rows))}proposeDimensions(){if(!this._terminal||!this._terminal.element||!this._terminal.element.parentElement)return;let r=this._terminal._core._renderService.dimensions;if(r.css.cell.width===0||r.css.cell.height===0)return;let i=this._terminal.options.scrollback===0?0:this._terminal.options.overviewRuler?.width||14,s=window.getComputedStyle(this._terminal.element.parentElement),l=parseInt(s.getPropertyValue("height")),o=Math.max(0,parseInt(s.getPropertyValue("width"))),a=window.getComputedStyle(this._terminal.element),n={top:parseInt(a.getPropertyValue("padding-top")),bottom:parseInt(a.getPropertyValue("padding-bottom")),right:parseInt(a.getPropertyValue("padding-right")),left:parseInt(a.getPropertyValue("padding-left"))},h=n.top+n.bottom,m=n.right+n.left,p=l-h,c=o-m-i;return{cols:Math.max(e,Math.floor(c/r.css.cell.width)),rows:Math.max(t,Math.floor(p/r.css.cell.height))}}};export{r as FitAddon};

