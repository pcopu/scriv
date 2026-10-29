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
    if(d.characterLinks!==undefined&&d.characterLinks!==null){
      assert(Array.isArray(d.characterLinks)&&d.characterLinks.length<=text.length,400,'invalid_character_links','Character links must be bounded text annotations.');
      let end=0;const linkIds=new Set<string>();
      for(const raw of d.characterLinks){const link=record(raw,'characterLink'),linkId=id(link.id,'characterLink.id');
        assert(!linkIds.has(linkId),400,'invalid_character_links','Character link IDs must be unique.');linkIds.add(linkId);
        const location=int(link.location,'characterLink.location',end,text.length),length=int(link.length,'characterLink.length',1,text.length-location);
        assert(str(link.text,'characterLink.text',50000)===text.slice(location,location+length),400,'invalid_character_links','Character links must preserve the exact authored UTF-16 text range.');
        assert(typeof link.isConfirmed==='boolean',400,'invalid_character_links','Character links require an explicit confirmation state.');
        if(link.characterId!==undefined&&link.characterId!==null)id(link.characterId,'characterLink.characterId');
        else assert(link.isConfirmed===true,400,'invalid_character_links','An unlinked text range requires explicit confirmation.');
        const splitsSurrogate=(offset:number)=>offset>0&&offset<text.length&&text.charCodeAt(offset-1)>=0xd800&&text.charCodeAt(offset-1)<=0xdbff&&text.charCodeAt(offset)>=0xdc00&&text.charCodeAt(offset)<=0xdfff;
        assert(!splitsSurrogate(location)&&!splitsSurrogate(location+length),400,'invalid_character_links','Character links cannot split a Unicode character.');end=location+length;
      }
    }
    assert(Array.isArray(d.words)&&d.words.length<=10000,400,'invalid_words','Entry words must be an array.');
    if(d.kind==='direction')assert(d.words.length===0&&coverage>=duration,400,'direction_timing','Directions are unspoken and coverage must reach at least their owned end.');
    else{
      const source=text.match(/\S+/gu)??[];assert(source.length===d.words.length,400,'word_order','Word timings must preserve the exact script words.');
      let previous=0;const ids=new Set<string>();
      d.words.forEach((raw,i)=>{const w=record(raw,'word');assert(w.timingSource===undefined||w.timingSource===null||w.timingSource==='authored',400,'invalid_word_timing_source','Word timingSource must be authored when present.');const wordId=id(w.id,'word.id');assert(!ids.has(wordId),400,'duplicate_word','Word IDs must be unique in a line.');ids.add(wordId);assert(str(w.text,'word.text',10000)===source[i],400,'word_order','Words must preserve script order and wording.');const start=int(w.startMs,'word.startMs',previous,duration);const end=int(w.endMs,'word.endMs',start+1,duration);previous=end;});
    }
  }
  if(item.kind==='character'){str(d.name,'character.name',200);strings(d.aliases,'aliases');str(d.biography,'biography',20000,0);str(d.appearance,'appearance',20000,0);str(d.color,'color',50,0);if(d.portraitImageId!==undefined&&d.portraitImageId!==null)id(d.portraitImageId,'portraitImageId');}
  if(item.kind==='image'){
    int(d.version,'image.version',1);const name=str(d.fileName,'fileName',255);assert(!name.includes('/')&&!name.includes('\\')&&!name.includes('..'),400,'invalid_filename','Image fileName must be a local filename.');
    assert(typeof d.sha256==='string'&&/^[a-fA-F0-9]{64}$/.test(d.sha256),400,'invalid_hash','Images require a SHA-256 digest.');
    assert(['image/png','image/jpeg','image/webp'].includes(String(d.mimeType)),400,'invalid_media','Supported image types are PNG, JPEG and WebP.');int(d.byteCount,'byteCount',1,26214400);const characterIds=strings(d.characterIds,'characterIds',100);assert(new Set(characterIds).size===characterIds.length,400,'duplicate_character','Image character tags must be distinct.');str(d.prompt,'prompt',30000,0);assert(typeof d.createdAt==='number'&&Number.isFinite(d.createdAt)&&d.createdAt>=0,400,'invalid_timestamp','createdAt must be milliseconds since the Unix epoch.');
    // The captured submitted prompt is distinct from editable manual direction.
    // Legacy/imported images may truthfully have no captured generation text.
    if(d.generationPrompt!==undefined&&d.generationPrompt!==null)str(d.generationPrompt,'generationPrompt',30000,0);
    if(d.previousVersionId!==undefined&&d.previousVersionId!==null)id(d.previousVersionId,'previousVersionId');
  }
  if(item.kind==='cue'){
    const hasAnchor=d.startAnchor!==undefined&&d.startAnchor!==null,hasDuration=d.authoredDurationMs!==undefined&&d.authoredDurationMs!==null;
    assert(hasAnchor===hasDuration,400,'invalid_cue_anchor','Image source anchors and authored duration must be supplied together.');
    if(hasAnchor){const anchor=record(d.startAnchor,'startAnchor');id(anchor.entryId,'startAnchor.entryId');int(anchor.offsetMs,'startAnchor.offsetMs',0,3599999);int(d.authoredDurationMs,'authoredDurationMs',1,86400000);}
    id(d.sceneId,'sceneId');const start=int(d.startMs,'startMs',0,86400000);int(d.endMs,'endMs',start+(hasAnchor?0:1),86400000);str(d.label,'cue.label',200,0);str(d.prompt,'cue.prompt',30000,0);if(d.imageId!==undefined&&d.imageId!==null)id(d.imageId,'imageId');}
}
