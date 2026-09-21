using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using System;
using System.Collections.Generic;
using System.Data.Entity;
using System.Linq;
using System.Linq.Expressions;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Repository
{
    public class SQLRepository<T> : IRepository<T> where T : class
    {
        private CPHContext context;
        private DbSet<T> dbSet;

        public SQLRepository()
        {
            this.context = new CPHContext();
            dbSet = context.Set<T>();
        }

        public SQLRepository(CPHContext context)
        {
            this.context = context;
            dbSet = context.Set<T>();
        }

        public virtual IEnumerable<T> FindBy(Expression<Func<T, bool>> predicate)
        {
            return dbSet.Where(predicate);
        }

        public virtual T First(Expression<Func<T, bool>> predicate)
        {
            return dbSet.First<T>(predicate);
        }

        public virtual T FirstOrDefault(Expression<Func<T, bool>> predicate)
        {
            return dbSet.FirstOrDefault<T>(predicate);
        }

        public virtual IEnumerable<T> GetAll()
        {
            return dbSet;
        }

        public virtual IEnumerable<T> GetAllNoTracking()
        {
            return dbSet.AsNoTracking();
        }

        public virtual T GetById(object id)
        {
            return dbSet.Find(id);
        }

        public virtual void Create(T obj)
        {
            dbSet.Add(obj);
        }

        public virtual void Update(T obj)
        {
            dbSet.Attach(obj);
            context.Entry(obj).State = EntityState.Modified;
        }

        public virtual void Delete(object id)
        {
            T obj = dbSet.Find(id);
            Delete(obj);
        }

        public virtual void Delete(T obj)
        {
            if (context.Entry(obj).State == EntityState.Detached)
            {
                dbSet.Attach(obj);
            }

            dbSet.Remove(obj);
        }
    }
}
