select name from sys.databases;

use testdb;

-- drop table testtable;

create table testtable
(
  id int not null identity primary key,
  somestring varchar(1000),
  somejsonstring varchar(1000),
  someint int,
  somedate datetime
);

insert into testtable (somestring, somejsonstring, someint, somedate)
values ('aaa111', null, 111, '2022-01-02 01:02:03');

insert into testtable (somestring, somejsonstring, someint, somedate)
values ('bbb' + char(10) + 'ccc' + char(13) + '\111ddd"222', null, 222, '2022-01-01 01:02:04');

insert into testtable (somestring, somejsonstring, someint, somedate)
values (null, '{"ccc":"aaa","ddd":111,"eee":true,"fff":null}', 333, '2022-01-01 01:02:05');

insert into testtable (somestring, somejsonstring, someint, somedate)
values (null, 'ddd', 444, '2022-01-01 01:02:06');

select * from testtable;
