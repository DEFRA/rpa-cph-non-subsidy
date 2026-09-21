using RPA.CPH.NonSubsidy.Domain.Interfaces;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Linq.Expressions;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Repository
{
    public class FakeRepository<T> : IRepository<T> where T : class
    {
        private List<T> data = new List<T>();

        public IEnumerable<T> FindBy(Expression<Func<T, bool>> predicate)
        {
            return data.Where(predicate.Compile());
        }

        public IEnumerable<T> FindByNoTracking(Expression<Func<T, bool>> predicate)
        {
            return data.Where(predicate.Compile());
        }

        public T First(Expression<Func<T, bool>> predicate)
        {
            return data.First(predicate.Compile());
        }

        public T FirstOrDefault(Expression<Func<T, bool>> predicate)
        {
            return data.FirstOrDefault(predicate.Compile());
        }

        public IEnumerable<T> GetAll()
        {
            return data;
        }

        public IEnumerable<T> GetAllNoTracking()
        {
            return data;
        }

        public T GetById(object id)
        {
            return data.FirstOrDefault();
        }

        public void Create(T obj)
        {
            data.Add(obj);
        }

        public void Update(T obj)
        {
            T existing = data.FirstOrDefault();
            existing = obj;
        }

        public void Delete(object id)
        {
            data.RemoveAt(0);
        }

        public void Delete(T obj)
        {
            data.Remove(obj);
        }
    }
}
