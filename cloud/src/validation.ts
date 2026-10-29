import type { Item, ItemKind } from './types';
import { assert, id, int, record, str } from './http';
export const itemKinds: ItemKind[] = ['scene','entry','character','image','cue'];
function strings(value: unknown,name:string,max=100): string[] {assert(Array.isArray(value)&&value.length<=max,400,'invalid_field',`${name} must be an array of at most ${max} strings.`);return value.map(v=>str(v,name,500));}
export function validateItem(item: Pick<Item,'id'|'kind'|'data'>): void {
  const d=item.data;assert(d.id===item.id,400,'item_identity','Item data.id must match the item identity.');
  assert(new TextEncoder().encode(JSON.stringify(d)).byteLength<=65536,413,'item_too_large','A single item cannot exceed 64 KiB.');
  if(item.kind==='scene'){str(d.title,'scene.title',500,0);assert(typeof d.order==='number'&&Number.isFinite(d.order),400,'invalid_order','Scene order must be finite.');}
  if(item.kind==='entry'){
    id(d.sceneId,'sceneId');assert(typeof d.order==='number'&&Number.isFinite(d.order),400,'invalid_order','Entry order must be finite.');
    assert(['dialogue','direction'].includes(String(d.kind)),400,'invalid_kind','Entry must be dialogue or direction.');
    const text=str(d.text,'entry.text',50000,0);const duration=int(d.ownedDurationMs,'ownedDurationMs',d.kind==='dialogue'?1:0,3600000);
    const coverage=int(d.coverageDurationMs,'coverageDurationMs',0,86400000);str(d.color,'color',50,0);
    if(d.characterId!==undefined&&d.characterId!==null)id(d.characterId,'characterId');
    assert(Array.isArray(d.words)&&d.words.length<=10000,400,'invalid_words','Entry words must be an array.');
    if(d.kind==='direction')assert(d.words.length===0&&coverage>=duration,400,'direction_timing','Directions are unspoken and coverage must reach at least their owned end.');
    else{
      const source=text.match(/\S+/gu)??[];assert(source.length===d.words.length,400,'word_order','Word timings must preserve the exact script words.');
      let previous=0;const ids=new Set<string>();
      d.words.forEach((raw,i)=>{const w=record(raw,'word');const wordId=id(w.id,'word.id');assert(!ids.has(wordId),400,'duplicate_word','Word IDs must be unique in a line.');ids.add(wordId);assert(str(w.text,'word.text',10000)===source[i],400,'word_order','Words must preserve script order and wording.');const start=int(w.startMs,'word.startMs',previous,duration);const end=int(w.endMs,'word.endMs',start+1,duration);previous=end;});
    }
  }
  if(item.kind==='character'){str(d.name,'character.name',200);strings(d.aliases,'aliases');str(d.biography,'biography',20000,0);str(d.appearance,'appearance',20000,0);str(d.color,'color',50,0);if(d.portraitImageId!==undefined&&d.portraitImageId!==null)id(d.portraitImageId,'portraitImageId');}
  if(item.kind==='image'){
    int(d.version,'image.version',1);const name=str(d.fileName,'fileName',255);assert(!name.includes('/')&&!name.includes('\\')&&!name.includes('..'),400,'invalid_filename','Image fileName must be a local filename.');
    assert(typeof d.sha256==='string'&&/^[a-fA-F0-9]{64}$/.test(d.sha256),400,'invalid_hash','Images require a SHA-256 digest.');
    assert(['image/png','image/jpeg','image/webp'].includes(String(d.mimeType)),400,'invalid_media','Supported image types are PNG, JPEG and WebP.');int(d.byteCount,'byteCount',1,26214400);strings(d.characterIds,'characterIds',100);str(d.prompt,'prompt',30000,0);assert(typeof d.createdAt==='number'&&Number.isFinite(d.createdAt)&&d.createdAt>=0,400,'invalid_timestamp','createdAt must be milliseconds since the Unix epoch.');
    if(d.previousVersionId!==undefined&&d.previousVersionId!==null)id(d.previousVersionId,'previousVersionId');
  }
  if(item.kind==='cue'){id(d.sceneId,'sceneId');const start=int(d.startMs,'startMs',0,86400000);int(d.endMs,'endMs',start+1,86400000);str(d.label,'cue.label',200,0);str(d.prompt,'cue.prompt',30000,0);if(d.imageId!==undefined&&d.imageId!==null)id(d.imageId,'imageId');}
}
