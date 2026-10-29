import { describe, expect, it } from 'vitest';
import { validateItem } from '../src/validation';
import type { Item } from '../src/types';
function entry(characterLinks?:unknown):Pick<Item,'id'|'kind'|'data'>{return{id:'entry',kind:'entry',data:{id:'entry',sceneId:'scene',order:0,kind:'direction',text:'🎬 Randy',ownedDurationMs:0,coverageDurationMs:1000,color:'blue',words:[],...(characterLinks===undefined?{}:{characterLinks})}};}
const link={id:'link',characterId:'randy',location:3,length:5,text:'Randy',isConfirmed:false};
describe('authored optional schema validation',()=>{
  it('accepts legacy annotations and confirmed explicit unlink in Swift omitted/null form',()=>{
    for(const links of [undefined,null,[],[link],[{...link,characterId:undefined,isConfirmed:true}],[{...link,characterId:null,isConfirmed:true}]])expect(()=>validateItem(entry(links))).not.toThrow();
  });
  it('rejects identity/range drift, overlapping links, duplicate IDs and half-surrogate ranges',()=>{
    for(const links of [[{...link,text:'Jason'}],[{...link,location:2}],[link,link],[{...link,characterId:null}],[{...link,location:0,length:1,text:'\ud83c'}],[{...link,isConfirmed:'true'}]])expect(()=>validateItem(entry(links))).toThrow();
  });
  it('requires source anchor/duration pairs and restricts authored-word provenance',()=>{
    const cue:Pick<Item,'id'|'kind'|'data'>={id:'cue',kind:'cue',data:{id:'cue',sceneId:'scene',label:'',prompt:'',startMs:0,endMs:1000}};
    expect(()=>validateItem(cue)).not.toThrow();expect(()=>validateItem({...cue,data:{...cue.data,startAnchor:{entryId:'entry',offsetMs:0}}})).toThrow();
    expect(()=>validateItem({...cue,data:{...cue.data,startAnchor:{entryId:'entry',offsetMs:0},authoredDurationMs:1000}})).not.toThrow();
    const dialogue=entry();dialogue.data={...dialogue.data,kind:'dialogue',text:'Hello',ownedDurationMs:1000,words:[{id:'word',text:'Hello',startMs:0,endMs:1000,timingSource:'guessed'}]};
    expect(()=>validateItem(dialogue)).toThrow();(dialogue.data.words as any[])[0].timingSource='authored';expect(()=>validateItem(dialogue)).not.toThrow();
  });
});
