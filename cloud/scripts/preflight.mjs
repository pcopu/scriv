import { readFile } from 'node:fs/promises';
const config=JSON.parse(await readFile(new URL('../wrangler.jsonc',import.meta.url),'utf8'));
const errors=[];
let origin;
try{origin=new URL(config.vars.PUBLIC_URL);if(origin.protocol!=='https:'||/YOUR_|example\./i.test(origin.hostname))errors.push('Set vars.PUBLIC_URL to the real HTTPS API origin.');}catch{errors.push('Set a valid PUBLIC_URL.');}
if(!config.d1_databases?.[0]?.database_id||config.d1_databases[0].database_id==='00000000-0000-0000-0000-000000000000')errors.push('Create the D1 database and set its database_id.');
if(!config.r2_buckets?.[0]?.bucket_name)errors.push('Set the private R2 bucket name.');
const emailSender=config.vars.EMAIL_FROM;
if(typeof emailSender!=='string'||!/^[-a-zA-Z0-9.!#$%&'*+/=?^_`{|}~]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(emailSender))errors.push('Set vars.EMAIL_FROM to the verified production sender address.');
const emailBinding=config.send_email?.find(binding=>binding.name==='EMAIL');
if(!emailBinding||emailBinding.remote||emailBinding.allowed_sender_addresses?.length!==1||emailBinding.allowed_sender_addresses[0]!==emailSender)errors.push('Configure the EMAIL sending binding restricted to EMAIL_FROM; do not enable remote email sending in checked-in local tests.');
if(config.vars.ENVIRONMENT!=='production')errors.push('Production ENVIRONMENT must be production.');
if(errors.length){for(const error of errors)console.error(error);process.exit(1);}
console.log('Cloud bindings configured. Verify the email sender DNS, apply migrations, and deploy. Stripe billing and TURN relay remain optional and must not be represented as configured unless separately verified.');
