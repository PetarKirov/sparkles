import { greet } from '@sample/greeter';

const name = process.argv[2] ?? 'world';
console.log(greet(name));
