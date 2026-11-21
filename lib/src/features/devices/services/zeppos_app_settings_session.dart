import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';
import 'package:oronbox/src/app/webview/app_webview_session.dart';
import 'package:oronbox/src/core/errors/platform_capability_error.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/device/zeppos/app_side/zeppos_app_side_storage.dart';

class ZeppOsAppSettingsSession {
  ZeppOsAppSettingsSession(this.appId);

  final int appId;
  final _storage = ZeppOsAppSideStorage();
  final _coordinator = ZeppOsSettingsCoordinator.instance;
  final _log = getLogger('ZeppOsAppSettings');
  final _origin = Object();
  AppWebViewSession? _view;
  StreamSubscription<Map<String, Object?>>? _browserEvents;
  StreamSubscription<ZeppOsSettingsChange>? _subscription;
  Future<void>? _initializing;
  Future<void>? _closing;
  Future<void>? _releasing;
  Future<void> _messages = Future.value();
  Future<void> _updates = Future.value();
  bool _closed = false;
  bool _documentReady = false;

  WebViewController get controller => _view!.controller;
  AppWebViewSession? get browser => _view;

  Future<void> initialize({
    void Function(Object)? onLoadError,
    bool detached = false,
    String? title,
  }) => _initializing ??= _initialize(onLoadError, detached, title);

  Future<void> _initialize(
    void Function(Object)? onLoadError,
    bool detached,
    String? title,
  ) async {
    try {
      _ensureOpen();
      if (kIsWeb) {
        throw const PlatformCapabilityError(
          'Zepp OS app settings are unavailable on web',
        );
      }
      final script = await _storage.readSetting(appId);
      if (script == null) throw StateError('No cached setting.js');
      final assets = await _storage.readSettingAssets(appId);
      final settings = await _coordinator.read(appId);
      _ensureOpen();
      final view = AppWebViewSession({
        'html': _runtimeHtml(appId, script, settings, assets),
        'ephemeral': true,
        'controlled-html': true,
        'channels': ['ZeppSettingsBridge'],
        if (title != null) 'title': title,
      });
      _view = view;
      _browserEvents = view.events.listen((event) {
        if (_closed) return;
        switch (event['type']) {
          case 'message':
            _messages = _messages
                .then((_) => _handleMessage(event['message'] as String))
                .catchError((Object error, StackTrace stack) {
                  _log.warning('Settings message failed', error, stack);
                });
          case 'loaded':
            _documentReady = true;
            _queueSettingsUpdate();
          case 'external':
            unawaited(_openExternal(event['url'] as String));
          case 'error':
            onLoadError?.call(event['message'] ?? 'WebView load failed');
        }
      });
      _subscription = _coordinator.changesFor(appId).listen((change) {
        if (!identical(change.origin, _origin)) _queueSettingsUpdate();
      });
      await view.initialize(detached: detached);
      _ensureOpen();
    } catch (_) {
      _closed = true;
      await _release();
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Settings session closed');
  }

  void _queueSettingsUpdate() {
    if (_closed || !_documentReady) return;
    _updates = _updates
        .then((_) async {
          final values = await _coordinator.read(appId);
          if (_closed) return;
          await _view!.invoke(
            'script',
            'globalThis.__oronboxSettingsChanged(${jsonEncode(values)})',
          );
        })
        .catchError((Object error, StackTrace stack) {
          _log.warning('Settings update failed', error, stack);
        });
  }

  Future<void> _handleMessage(String message) async {
    final value = jsonDecode(message);
    if (value is! Map) throw const FormatException('Invalid settings message');
    switch (value['type']) {
      case 'settings':
        final key = value['key'];
        switch (value['operation']) {
          case 'set' when key is String:
            await _coordinator.set(
              appId,
              key,
              value['value']?.toString() ?? '',
              origin: _origin,
            );
          case 'remove' when key is String:
            await _coordinator.remove(appId, key, origin: _origin);
          case 'clear':
            await _coordinator.clear(appId, origin: _origin);
          default:
            throw const FormatException('Invalid settings operation');
        }
      case 'log':
        _log.info(
          '[${appId.toRadixString(16)} setting.js] ${value['message']}',
        );
      case 'external':
        if (!_closed) await _openExternal(value['url']?.toString() ?? '');
      default:
        throw const FormatException('Unknown settings message');
    }
  }

  Future<void> _openExternal(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error, stack) {
      _log.warning('Settings link failed', error, stack);
    }
  }

  Future<void> close() {
    _closed = true;
    _view?.markClosed();
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      await _initializing;
    } catch (_) {
      // Initialization reports its own failure to the page.
    }
    await _release();
  }

  Future<void> _release() => _releasing ??= _releaseOwned();

  Future<void> _releaseOwned() async {
    await _subscription?.cancel();
    _subscription = null;
    await _browserEvents?.cancel();
    await _messages;
    await _updates;
    final view = _view;
    _view = null;
    await view?.close();
  }
}

String _runtimeHtml(
  int appId,
  String source,
  Map<String, String> initialSettings,
  Map<String, Uint8List> assets,
) {
  final encodedSource = base64Encode(utf8.encode(source));
  final encodedSettings = base64Encode(
    utf8.encode(jsonEncode(initialSettings)),
  );
  final encodedAssets = jsonEncode({
    for (final entry in assets.entries)
      entry.key.replaceAll('\\', '/'): _dataUri(entry.key, entry.value),
  });
  return '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>:root{color-scheme:light dark;font:16px system-ui,sans-serif}html,body{width:100%;height:100%;margin:0;overflow:hidden;background:Canvas;color:CanvasText}*,*::before,*::after{box-sizing:border-box}.root{width:100%;height:100%;overflow:auto;overscroll-behavior:contain}.root>div{width:100%;margin-inline:auto}.section{padding:16px;border:1px solid color-mix(in srgb,CanvasText 20%,transparent);border-radius:16px}.section h2{font-size:18px;margin:0 0 4px}.section p{opacity:.7;margin:0 0 12px}.row{display:flex;align-items:center;gap:12px;min-height:44px}.row-main{display:flex;flex:1;flex-direction:column;min-width:0}.label{font-weight:600;margin-bottom:6px}.sublabel{opacity:.7;font-size:.9em}button,input,select,textarea{font:inherit;padding:10px 12px;border-radius:12px;border:1px solid color-mix(in srgb,CanvasText 30%,transparent);max-width:100%}button{cursor:pointer}img{max-width:100%}.custom-select{position:relative}.custom-select>select{position:absolute!important;inset:0!important;width:100%!important;height:100%!important;opacity:0;cursor:pointer;z-index:2}.custom-select>span{position:relative;z-index:1;pointer-events:none}.responsive-row{min-width:0}.responsive-row>*{min-width:0}.error{white-space:pre-wrap;background:#b3261e;color:white;padding:16px;border-radius:12px}.toast{position:fixed;left:50%;transform:translateX(-50%);padding:12px 20px;border-radius:999px;background:#323232;color:white;z-index:10}.toast.top{top:24px}.toast.bottom{bottom:24px}@media(max-width:600px){.root>div{max-width:100%!important;padding-left:12px!important;padding-right:12px!important}.row,.responsive-row{flex-wrap:wrap!important}button,input,select,textarea{min-width:0}.responsive-row>div{flex-basis:180px}}</style></head><body><main id="root" class="root"></main><script>
'use strict';
const decode=s=>new TextDecoder().decode(Uint8Array.from(atob(s),c=>c.charCodeAt(0)));
const __appId=$appId,__source=decode('$encodedSource'),__values=new Map(Object.entries(JSON.parse(decode('$encodedSettings')))),__assets=$encodedAssets;
const post=message=>{const text=JSON.stringify(message);ZeppSettingsBridge.postMessage(text)};
const fmt=args=>args.map(v=>{try{if(typeof v==='string')return v;if(v instanceof Error)return v.stack||v.message||String(v);const json=JSON.stringify(v);return json==='{}'&&v?.message?String(v.message):json??String(v)}catch(_){return String(v)}}).join(' ');let __lastLog='';
globalThis.console={};for(const level of ['log','error','warn','info','debug'])console[level]=(...args)=>{__lastLog=fmt(args);post({type:'log',level,message:__lastLog})};
const __language=(navigator.language||'en-US').replace('_','-');globalThis.userSettings={lang:__language,language:__language};
class ZeppLang{constructor(lang){this.lang=lang||__language}getLang(){return this.lang}setLang(lang){this.lang=lang}}
function zeppFormat(text,...args){let index=0;return String(text).replace(/%([%sdif])/g,(all,type)=>{if(type==='%')return'%';const value=args[index++];if(type==='d'||type==='i')return String(parseInt(value,10));if(type==='f')return String(Number(value));return String(value??'')})}
function gettextFactory(table,current,defaultLang){let lang=current instanceof ZeppLang?current:new ZeppLang(current);let messages=table?.[lang.getLang()]||table?.[lang.getLang().split('-')[0]]||table?.[defaultLang]||{};const gettext=(id,...args)=>zeppFormat(messages[id]??id,...args);gettext.locale=locale=>{lang.setLang(locale);messages=table?.[locale]||table?.[String(locale).split('-')[0]]||table?.[defaultLang]||{}};return gettext}
globalThis.HmUtils={Lang:ZeppLang,gettextFactory,getLanguage:settings=>settings?.lang||__language,getSideLanguage:settings=>settings?.lang||__language,getDeviceLanguage:()=>__language,format:zeppFormat,formatStrict:zeppFormat,printf:(message,...args)=>console.log(zeppFormat(message,...args)),sprintf:zeppFormat};
const listeners=[];const settingsStorage={get length(){return __values.size},getItem(k){k=String(k);return __values.has(k)?__values.get(k):null},setItem(k,v){k=String(k);v=String(v);const oldValue=__values.get(k);__values.set(k,v);post({type:'settings',operation:'set',key:k,value:v});notify({key:k,oldValue,newValue:v});if(__appId===0x0010ee3b&&k==='localMessages'&&v==='[]')setTimeout(()=>{settingsStorage.setItem('action','');setTimeout(()=>settingsStorage.setItem('action','sendBleChat'),80)},0);if(__appId===0x0010ee3b&&k==='action'&&v==='login')setTimeout(()=>{if(__values.get('action')==='login'&&__values.get('isLoggedIn')!=='true')showStatus('登录请求已发送，但 app-side 尚未返回结果。请确认 app-side 正在运行并检查账号或网络。',true)},10000)},removeItem(k){k=String(k);if(!__values.has(k))return;const oldValue=__values.get(k);__values.delete(k);post({type:'settings',operation:'remove',key:k});notify({key:k,oldValue,newValue:undefined})},clear(){const old=[...__values];__values.clear();post({type:'settings',operation:'clear'});for(const [key,oldValue] of old)notify({key,oldValue,newValue:undefined})},key(i){return [...__values.keys()][i]??null},toObject(){return Object.fromEntries(__values)},addListener(e,fn){if(e==='change'&&typeof fn==='function'&&!listeners.includes(fn))listeners.push(fn)},removeListener(e,fn){if(e==='change'){const i=listeners.indexOf(fn);if(i>=0)listeners.splice(i,1)}}};
function notify(change){for(const fn of [...listeners])try{fn(change)}catch(e){showError(e)}}
let pageOption;function AppSettingsPage(option){pageOption=option;rebuild()}globalThis.AppSettingsPage=AppSettingsPage;
function node(type,props={},children=[]){return{type,props:props||{},children:Array.isArray(children)?children:[children]}}for(const name of ['Auth','Button','Image','Link','Section','Select','Slider','Text','TextImageRow','TextInput','Toast','Toggle','View'])globalThis[name]=(props,children)=>node(name,props,children);
const unitlessStyle=new Set(['opacity','zIndex','fontWeight','lineHeight','flex','flexGrow','flexShrink','order','zoom']);function normalizedStyle(input){const style={...input};for(const [key,value]of Object.entries(style))if(typeof value==='number'&&value!==0&&!unitlessStyle.has(key))style[key]=value+'px';return style}function apply(el,p){if(p.style&&typeof p.style==='object'){const style=normalizedStyle(p.style);if((style.overflowY==='auto'||style.overflowY==='scroll'||style.overflow==='scroll')&&(style.height==='100vh'||style.maxHeight==='100vh'||style.minHeight==='100vh')){delete style.height;delete style.maxHeight;style.overflow='visible';style.overflowY='visible'}if(style.flexDirection==='row')el.classList.add('responsive-row');Object.assign(el.style,style)}}function textValue(c){return c.flat(Infinity).filter(v=>v!=null&&typeof v!=='object').map(String).join('')}function asset(value){if(!value)return'';let path=String(value).split(String.fromCharCode(92)).join('/');if(path.startsWith('./'))path=path.slice(2);return __assets[path]||__assets[Object.keys(__assets).find(k=>k.endsWith('/'+path))]||value}function bound(p,fallback){return p.settingsKey&&__values.has(String(p.settingsKey))?__values.get(String(p.settingsKey)):p.value??fallback}function change(p,value,rebuildAfter=true){if(p.settingsKey)settingsStorage.setItem(String(p.settingsKey),Array.isArray(value)?JSON.stringify(value):String(value));if(typeof p.onChange==='function')p.onChange(value);if(rebuildAfter)queueMicrotask(rebuild)}function invoke(handler){try{return handler?.()}finally{queueMicrotask(rebuild)}}function labeled(p,control){if(!p.label&&!p.title)return control;const row=document.createElement('label');row.className='row';const main=document.createElement('span');main.className='row-main';const label=document.createElement('span');label.className='label';label.textContent=p.label??p.title;if(p.labelStyle&&typeof p.labelStyle==='object')Object.assign(label.style,normalizedStyle(p.labelStyle));main.append(label);if(p.sublabel){const sub=document.createElement('span');sub.className='sublabel';sub.textContent=p.sublabel;main.append(sub)}row.append(main,control);return row}
function render(item){if(item==null||item===false)return document.createTextNode('');if(typeof item==='string'||typeof item==='number')return document.createTextNode(String(item));if(Array.isArray(item)){const f=document.createDocumentFragment();item.forEach(x=>f.append(render(x)));return f}const p=item.props||{},c=item.children||[];let e;
switch(item.type){case'Text':e=document.createElement('span');e.textContent=p.text??p.label??textValue(c);break;case'Button':e=document.createElement('button');e.textContent=p.label??p.text??textValue(c);e.onclick=()=>invoke(p.onClick);break;case'View':e=document.createElement('div');if(p.onClick)e.onclick=()=>invoke(p.onClick);e.append(render(c));if(c.some?.(x=>x?.type==='Select')&&c.some?.(x=>x?.type==='Text'))e.classList.add('custom-select');break;case'Section':e=document.createElement('section');e.className='section';if(p.title){const h=document.createElement('h2');h.textContent=p.title;e.append(h)}if(p.description){const d=document.createElement('p');d.textContent=p.description;e.append(d)}e.append(render(c));break;case'Image':e=document.createElement('img');e.src=asset(p.src??p.source);e.alt=p.alt??'';if(p.width)e.width=Number(p.width);if(p.height)e.height=Number(p.height);break;case'Link':e=document.createElement('a');e.href=p.source??'#';e.textContent=p.label??textValue(c)??p.source;e.onclick=ev=>{ev.preventDefault();post({type:'external',url:p.source})};break;case'Toggle':{const x=document.createElement('input');x.type='checkbox';x.checked=String(bound(p,false))==='true';x.onchange=()=>change(p,x.checked);if(p.subStyle)Object.assign(x.style,normalizedStyle(p.subStyle));e=labeled(p,x);if(c.length)e.prepend(render(c));break}case'TextInput':{const x=document.createElement(p.multiline?'textarea':'input');x.value=String(bound(p,''));x.placeholder=p.placeholder??'';x.disabled=!!p.disabled;if(p.rows)x.rows=Number(p.rows);if(p.subStyle&&typeof p.subStyle==='object')Object.assign(x.style,normalizedStyle(p.subStyle));x.onchange=()=>change(p,x.value,false);e=labeled(p,x);break}case'Slider':{const x=document.createElement('input');x.type='range';x.min=p.min??0;x.max=p.max??100;x.step=p.step??1;x.value=Number(bound(p,p.min??0));if(p.subStyle)Object.assign(x.style,normalizedStyle(p.subStyle));x.oninput=()=>change(p,Number(x.value));e=labeled(p,x);break}case'Select':{const x=document.createElement('select');x.multiple=!!p.multiple;for(const o of p.options||[]){const q=document.createElement('option');q.value=String(o.value);q.textContent=o.name??o.label??o.value;x.append(q)}let v=bound(p,p.multiple?[]:'');if(x.multiple){if(typeof v==='string')try{v=JSON.parse(v)}catch(_){v=v.split(',')}const a=Array.isArray(v)?v.map(String):[];for(const o of x.options)o.selected=a.includes(o.value)}else x.value=String(v);if(p.subStyle)Object.assign(x.style,normalizedStyle(p.subStyle));x.onchange=()=>change(p,x.multiple?[...x.selectedOptions].map(o=>o.value):x.value);e=labeled(p,x);break}case'Toast':e=document.createElement('div');e.className='toast '+(p.vertical==='bottom'?'bottom':'top');e.textContent=p.message??p.content??p.text??textValue(c);if(p.visible===false)e.hidden=true;if(p.visible!==false)setTimeout(()=>{e.remove();p.onClose?.()},p.duration??2000);break;case'TextImageRow':e=document.createElement('div');e.className='row';{const image=document.createElement('img');image.src=asset(p.icon);image.width=image.height=40;if(p.rounded)image.style.borderRadius='50%';const main=document.createElement('span');main.className='row-main';const label=document.createElement('span');label.textContent=p.label??'';main.append(label);if(p.sublabel){const sub=document.createElement('span');sub.className='sublabel';sub.textContent=p.sublabel;main.append(sub)}e.append(...(p.iconRight?[main,image]:[image,main]))}break;case'Auth':e=document.createElement('div');e.className='error';e.textContent='当前运行时不支持 OAuth Auth 组件';break;default:e=document.createElement('div');e.append(render(c))}apply(e,p);return e}
function showStatus(message,isError=false){const e=document.createElement('div');e.className='toast top';if(isError)e.style.background='#b3261e';e.textContent=message;document.body.append(e);setTimeout(()=>e.remove(),6000)}function showError(error){const root=document.getElementById('root');root.innerHTML='';const e=document.createElement('pre');e.className='error';e.textContent=String(error?.stack||error);root.append(e);post({type:'log',level:'error',message:e.textContent})}function rebuild(){if(!pageOption)return;try{const tree=pageOption.build.call(pageOption,{settingsStorage});document.getElementById('root').replaceChildren(render(tree))}catch(e){showError(e)}}
globalThis.eval=undefined;globalThis.Function=undefined;
try{const script=document.createElement('script');script.textContent=__source;document.head.append(script)}catch(e){showError(e)}
queueMicrotask(()=>{if(!pageOption)showError(new Error(__lastLog||'setting.js did not register AppSettingsPage'))});
globalThis.__oronboxSettingsChanged=raw=>{const next=typeof raw==='string'?JSON.parse(raw):raw;const old=new Map(__values);__values.clear();for(const [k,v] of Object.entries(next||{}))__values.set(k,String(v));for(const k of new Set([...old.keys(),...__values.keys()]))if(old.get(k)!==__values.get(k))notify({key:k,oldValue:old.get(k),newValue:__values.get(k)});rebuild()};
window.onerror=(m,s,l,c,e)=>{showError(e||new Error(String(m)));return true};window.onunhandledrejection=e=>showError(e.reason);
</script></body></html>''';
}

String _dataUri(String path, Uint8List bytes) {
  final extension = path.split('.').last.toLowerCase();
  final mime = switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    _ => 'application/octet-stream',
  };
  return 'data:$mime;base64,${base64Encode(bytes)}';
}
