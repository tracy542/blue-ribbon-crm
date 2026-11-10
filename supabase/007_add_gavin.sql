-- Gavin: associate broker, sees everything (loaded 11/10/2026)
insert into agents (company_id, office_id, full_name, email, role)
select c.id, o.id, 'Gavin Washington', 'gav@blueribbonrealty.com', 'broker'
from companies c join offices o on o.company_id = c.id
where c.name = 'Blue Ribbon Realty' and o.name = 'Martinsburg'
on conflict (email) do nothing;
