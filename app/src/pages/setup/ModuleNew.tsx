import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useModules } from '@/lib/data';
import { useFormErrors } from '@/lib/useFormErrors';
import { Button, ErrorText, Field, Input, PageHeader, Section } from '@/components/ui';

export default function ModuleNew() {
  const { domain } = useDomain();
  const modules = useModules(domain?.id);
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [name, setName] = useState('');
  const [order, setOrder] = useState<number | ''>('');
  const [err, setErr] = useState<unknown>(null);
  const nextOrder = (modules.data?.length ?? 0) + 1;
  const v = useFormErrors({
    name: !name.trim() ? 'Enter a name, for example Concurrency.' : undefined,
  });
  return (
    <div>
      <PageHeader
        title="Add module"
        breadcrumbs={[{ label: 'Modules', to: '/setup/modules' }, { label: 'Add module' }]}
      />
      <Section title="Module details" description={`The module is added to ${domain?.name}.`}>
        <div className="grid max-w-2xl gap-4 sm:grid-cols-2">
          <Field label="Name" required error={v.show('name')}>
            <Input
              value={name}
              autoFocus
              onBlur={v.touch('name')}
              onChange={(e) => setName(e.target.value)}
            />
          </Field>
          <Field label="Order in the rotation" hint={`Leave empty to put it last (${nextOrder}).`}>
            <Input
              type="number"
              min={1}
              value={order}
              onChange={(e) => setOrder(e.target.value ? Number(e.target.value) : '')}
            />
          </Field>
        </div>
        <ErrorText error={err} />
        <Button
          className="mt-4"
          onClick={async () => {
            if (!v.submit() || !domain) return;
            try {
              const m = check(
                await supabase
                  .from('module')
                  .insert({
                    domain_id: domain.id,
                    name: name.trim(),
                    rotation_order: order || nextOrder,
                  })
                  .select()
                  .single(),
              )!;
              toast.success('Module added');
              await qc.invalidateQueries();
              navigate(`/setup/modules/${m.id}?tab=times`);
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Add module
        </Button>
      </Section>
    </div>
  );
}
